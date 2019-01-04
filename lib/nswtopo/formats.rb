require_relative 'formats/svg'
require_relative 'formats/png'
require_relative 'formats/tif'
require_relative 'formats/jpg'
require_relative 'formats/kmz'
require_relative 'formats/mbtiles'
# require_relative 'formats/zip'
# require_relative 'formats/pdf'
# require_relative 'formats/psd'

# TODO: no need for nested modules, just use Formats.instance_methods.grep(/^render_\w+$)
# to detect available extensions

module NSWTopo
  module Formats
    def self.each(&block)
      modules = constants.map(&method(:const_get)).grep(Module).each
      block_given? ? tap { modules.each(&block) } : modules
    end
    extend Enumerable

    def self.included(mod)
      mod.include *self
    end

    def self.===(ext)
      map(&:ext).any?(ext)
    end

    each do |format|
      def format.ext
        name.split("::").last.downcase
      end
    end

    def rasterise(png_path, **options)
      browser = %w[firefox chrome].find &@config.method(:key?)
      raise "please specify a path to Google Chrome before creating raster output (see README)" unless browser
      puts "creating map raster at %i ppi using %s"    % [ options[:ppi],        browser ] if options[:ppi]
      puts "creating map raster at %.1f m/px using %s" % [ options[:resolution], browser ] if options[:resolution]
      browser_path = Pathname.new @config[browser]

      Dir.mktmppath do |temp_dir|
        svg_path = temp_dir / "map.svg"
        src_path = temp_dir / "browser.svg"
        screenshot_path = temp_dir / "screenshot.png"
        render_svg temp_dir, svg_path

        render = lambda do |width, height|
          args = case browser
          when "firefox"
            %W[--window-size=#{width},#{height} -headless -screenshot screenshot.png]
          when "chrome"
            %W[--window-size=#{width},#{height} --headless --screenshot --enable-logging --log-level=1 --disable-lcd-text --disable-extensions --hide-scrollbars --disable-gpu-rasterization]
          end
          FileUtils.rm screenshot_path if screenshot_path.exist?
          stdout, stderr, status = Open3.capture3 browser_path.to_s, *args, "file://#{src_path}"
          raise "couldn't rasterise map using %s" % browser unless status.success? && screenshot_path.file?
        rescue Errno::ENOENT
          raise "invalid %s path: %s" % [ browser, browser_path ]
        end

        dimensions, ppi, resolution = raster_dimensions **options
        Dir.chdir(temp_dir) do
          src_path.write %Q[<?xml version='1.0' encoding='UTF-8'?><svg version='1.1' baseProfile='full' xmlns='http://www.w3.org/2000/svg'></svg>]
          render.call 1000, 1000
          json = NSWTopo::OS.gdalinfo "-json", screenshot_path
          scaling = JSON.parse(json)["size"][0] / 1000.0

          svg = %w[width height].inject(svg_path.read) do |svg, attribute|
            svg.sub(/#{attribute}='(.*?)mm'/) { %Q[#{attribute}='#{$1.to_f * ppi / 96.0 / scaling}mm'] }
          end
          src_path.write svg
          render.call *(dimensions / scaling).map(&:ceil)
        end

        OS.mogrify "+repage", "-crop", "#{dimensions.join ?x}+0+0", "-units", "PixelsPerInch", "-density", ppi, "-background", "white", "-alpha", "Remove", "-define", "PNG:exclude-chunk=bkgd", screenshot_path
        FileUtils.mv screenshot_path, png_path
      end
    end
  end
end

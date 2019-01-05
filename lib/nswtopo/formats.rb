require_relative 'formats/svg'
require_relative 'formats/kmz'
require_relative 'formats/mbtiles'
require_relative 'formats/zip'
# require_relative 'formats/pdf'
# require_relative 'formats/psd'

module NSWTopo
  module Formats
    DEFAULT_PPI = 300
    DEFAULT_ZOOM = 16

    def self.extensions
      instance_methods.grep(/^render_([a-z]+)/) { $1 }
    end

    def self.===(ext)
      extensions.any? ext
    end

    def render_png(temp_dir, out_path, ppi: DEFAULT_PPI, dither: false, **options)
      # TODO: handle dithering if requested
      FileUtils.cp yield(ppi: ppi), out_path
    end

    def render_tif(temp_dir, tif_path, ppi: DEFAULT_PPI, dither: false, **options)
      # TODO: handle dithering if requested
      OS.gdal_translate "-of", "GTiff", "-a_srs", @projection, yield(ppi: ppi), tif_path
    end

    def render_jpg(temp_dir, jpg_path, ppi: DEFAULT_PPI, **options)
      OS.gdal_translate "-of", "JPEG", yield(ppi: ppi), jpg_path
    end

    def with_browser
      browser_name = %w[firefox chrome].find &@config.method(:key?)
      raise "please specify a path to google chrome (see README)" unless browser_name
      browser_path = Pathname.new @config[browser_name]
      yield browser_name, browser_path
    rescue Errno::ENOENT
      raise "invalid %s path: %s" % [ browser_name, browser_path ]
    end

    def rasterise(png_path, **options)
      Dir.mktmppath do |temp_dir|
        dimensions, ppi, resolution = raster_dimensions **options
        svg_path = temp_dir / "map.svg"
        src_path = temp_dir / "browser.svg"
        render_svg temp_dir, svg_path

        with_browser do |browser_name, browser_path|
          puts "creating map raster at %i ppi using %s"    % [ options[:ppi],        browser_name ] if options[:ppi]
          puts "creating map raster at %.1f m/px using %s" % [ options[:resolution], browser_name ] if options[:resolution]

          render = lambda do |width, height|
            args = case browser_name
            when "firefox"
              [ "--window-size=#{width},#{height}", "-headless", "-screenshot", png_path.to_s ]
            when "chrome"
              # TODO: --run-all-compositor-stages-before-draw flag?
              [ "--window-size=#{width},#{height}", "--headless", "--screenshot=#{png_path}", "--disable-lcd-text", "--disable-extensions", "--hide-scrollbars", "--disable-gpu-rasterization" ]
            end
            FileUtils.rm png_path if png_path.exist?
            stdout, stderr, status = Open3.capture3 browser_path.to_s, *args, "file://#{src_path}"
            case browser_name
            when "firefox" then raise "couldn't rasterise map using firefox (ensure browser is closed)"
            when "chrome" then raise "couldn't rasterise map using chrome"
            end unless status.success? && png_path.file?
          end

          src_path.write %Q[<?xml version='1.0' encoding='UTF-8'?><svg version='1.1' baseProfile='full' xmlns='http://www.w3.org/2000/svg'></svg>]
          render.call 1000, 1000
          json = NSWTopo::OS.gdalinfo "-json", png_path
          scaling = JSON.parse(json)["size"][0] / 1000.0

          svg = %w[width height].inject(svg_path.read) do |svg, attribute|
            svg.sub(/#{attribute}='(.*?)mm'/) { %Q[#{attribute}='#{$1.to_f * ppi / 96.0 / scaling}mm'] }
          end
          src_path.write svg
          render.call *(dimensions / scaling).map(&:ceil)
        end

        OS.mogrify "+repage", "-crop", "#{dimensions.join ?x}+0+0", "-units", "PixelsPerInch", "-density", ppi, "-background", "white", "-alpha", "Remove", "-define", "PNG:exclude-chunk=bkgd", png_path
      end
    end
  end
end

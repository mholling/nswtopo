module NSWTopo::Formats
  module Png
    def render_png(path, ppi:, dither: false, worldfile: false)
      # TODO: need to cache the PNG output here somehow for
      # situations where multiple raster types are requested.
      # maybe need to have a common temp_dir for the rendering
      # call.
      Dir.mktmppath do |temp_dir|
        svg_path = temp_dir / "map.svg"
        png_path = temp_dir / "map.#{ppi}.png"
        dimensions = raster_dimensions(ppi: ppi)
        zoom = ppi / 96.0
        render_svg svg_path

        case
        when browser = %w[firefox chrome].find(&@config.method(:key?))
          browser_path = Pathname.new @config[browser]
          puts "creating map raster at %i ppi using %s" % [ ppi, browser ]
          src_path = temp_dir / "browser.svg"
          screenshot_path = temp_dir / "screenshot.png"
          render = lambda do |width, height|
            args = case
            when @config["firefox"]
              %W[--window-size=#{width},#{height} -headless -screenshot screenshot.png]
            when @config["chrome"]
              %W[--window-size=#{width},#{height} --headless --screenshot --enable-logging --log-level=1 --disable-lcd-text --disable-extensions --hide-scrollbars --disable-gpu-rasterization]
            end
            FileUtils.rm screenshot_path if screenshot_path.exist?
            stdout, stderr, status = Open3.capture3 browser_path.to_s, *args, "file://#{src_path}"
            raise "couldn't rasterise map using %s" % browser unless status.success? && screenshot_path.file?
          rescue Errno::ENOENT
            raise "invalid %s path: %s" % [ browser, browser_path ]
          end
          Dir.chdir(temp_dir) do
            src_path.write %Q[<?xml version='1.0' encoding='UTF-8'?><svg version='1.1' baseProfile='full' xmlns='http://www.w3.org/2000/svg'></svg>]
            render.call 1000, 1000
            json = NSWTopo::OS.gdalinfo "-json", screenshot_path
            scaling = JSON.parse(json)["size"][0] / 1000.0
            svg = %w[width height].inject(svg_path.read) do |svg, attribute|
              svg.sub(/#{attribute}='(.*?)mm'/) { %Q[#{attribute}='#{$1.to_f * zoom / scaling}mm'] }
            end
            src_path.write svg
            render.call *(dimensions / scaling).map(&:ceil)
          end
          FileUtils.mv screenshot_path, png_path
        # # TODO: re-enable wkhtmltoimage and inkscape options...
        # when wkhtmltoimage = @config["wkhtmltoimage"]
        #   %x["#{wkhtmltoimage}" -q --width #{dimensions[0]} --height #{dimensions[1]} --zoom #{zoom} "#{svg_path}" "#{png_path}"]
        # when inkscape = @config["inkscape"]
        #   %x["#{inkscape}" --without-gui --file="#{svg_path}" --export-png="#{png_path}" --export-width=#{dimensions[0]} --export-height=#{dimensions[1]} --export-background="#FFFFFF" #{DISCARD_STDERR}]
        else
          raise "please specify a path to Google Chrome before creating raster output (see README)"
        end
        NSWTopo::OS.mogrify "+repage", "-crop", "#{dimensions.join ?x}+0+0", "-units", "PixelsPerInch", "-density", ppi, "-background", "white", "-alpha", "Remove", "-define", "PNG:exclude-chunk=bkgd", png_path
        # TODO: intercept interrupts
        # TODO: handle dither if requested
        FileUtils.mv png_path, path
      end
    end
  end
end

require_relative 'formats/svg'
require_relative 'formats/kmz'
require_relative 'formats/mbtiles'
require_relative 'formats/zip'
require_relative 'formats/pdf'
require_relative 'formats/svgz'

module NSWTopo
  module Formats
    include Log
    PPI = 300

    def self.extensions
      instance_methods.grep(/^render_([a-z]+)/) { $1 }
    end

    def self.===(ext)
      extensions.any? ext
    end

    def render_png(png_path, ppi: PPI, dither: false, **options)
      FileUtils.cp yield(ppi: ppi, dither: dither), png_path
    end

    def render_tif(tif_path, ppi: PPI, dither: false, **options)
      OS.gdal_translate "-of", "GTiff", "-co", "COMPRESS=DEFLATE", "-co", "ZLEVEL=9", "-a_srs", @projection, yield(ppi: ppi, dither: dither), tif_path
    end

    def render_jpg(jpg_path, ppi: PPI, **options)
      OS.gdal_translate "-of", "JPEG", "-co", "QUALITY=90", "-mo", "EXIF_XResolution=#{ppi}", "-mo", "EXIF_YResolution=#{ppi}", "-mo", "EXIF_ResolutionUnit=2", yield(ppi: ppi), jpg_path
    end

    def rasterise(png_path, external:, **options)
      Dir.mktmppath do |temp_dir|
        dimensions, ppi, resolution = raster_dimensions_at **options
        svg_path = temp_dir / "map.svg"
        src_path = temp_dir / "browser.svg"
        render_svg svg_path, external: external

        NSWTopo.with_browser do |browser_name, browser_path|
          megapixels = dimensions.inject(&:*) / 1024.0 / 1024.0
          log_update "%s: creating %i×%i (%.1fMpx) map raster at %i ppi"    % [browser_name, *dimensions, megapixels, options[:ppi]       ] if options[:ppi]
          log_update "%s: creating %i×%i (%.1fMpx) map raster at %.1f m/px" % [browser_name, *dimensions, megapixels, options[:resolution]] if options[:resolution]

          render = lambda do |width, height|
            args = case browser_name
            when "firefox"
              ["--window-size=#{width},#{height}", "-headless", "-screenshot", png_path.to_s]
            when "chrome"
              ["--window-size=#{width},#{height}", "--headless", "--screenshot=#{png_path}", "--disable-lcd-text", "--disable-extensions", "--hide-scrollbars", "--disable-gpu"]
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

        OS.mogrify "+repage", "-crop", "#{dimensions.join ?x}+0+0", "-background", "white", "-flatten", "-alpha", "Off", "-units", "PixelsPerInch", "-density", ppi, "-define", "PNG:exclude-chunk=bkgd,itxt,ztxt,text,chrm", png_path
      end
    end
  end
end

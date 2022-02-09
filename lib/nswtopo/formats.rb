require_relative 'formats/svg'
require_relative 'formats/kmz'
require_relative 'formats/mbtiles'
require_relative 'formats/gemf'
require_relative 'formats/zip'
require_relative 'formats/pdf'
require_relative 'formats/svgz'

module NSWTopo
  module Formats
    include Log
    PPI = 300
    PAGE = 2000

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
      OS.gdal_translate(
        "-of", "GTiff",
        "-co", "COMPRESS=DEFLATE",
        "-co", "ZLEVEL=9",
        "-mo", "TIFFTAG_XRESOLUTION=#{ppi}",
        "-mo", "TIFFTAG_YRESOLUTION=#{ppi}",
        "-mo", "TIFFTAG_RESOLUTIONUNIT=2",
        "-a_srs", @projection,
        yield(ppi: ppi, dither: dither),
        tif_path
      )
    end

    def render_jpg(jpg_path, ppi: PPI, **options)
      OS.gdal_translate "-of", "JPEG", "-co", "QUALITY=90", "-mo", "EXIF_XResolution=#{ppi}", "-mo", "EXIF_YResolution=#{ppi}", "-mo", "EXIF_ResolutionUnit=2", yield(ppi: ppi), jpg_path
    end

    def rasterise(png_path, external:, ppi: nil, **options)
      Dir.mktmppath do |temp_dir|
        svg_path = temp_dir / "map.svg"
        src_path = temp_dir / "browser.svg"
        vrt_path = temp_dir / "map.vrt"

        render_svg svg_path, external: external
        xml = REXML::Document.new svg_path.read

        case
        when !external
          raster_dimensions, ppi, resolution = raster_dimensions_at ppi: ppi, **options
        when ppi
          raster_dimensions = xml.elements["svg"].attributes.values_at("width", "height").map do |attribute|
            attribute.value.to_f * ppi / 25.4
          end.map(&:ceil)
        else
          raise "must specify ppi when using an external svg"
        end

        NSWTopo.with_chrome do |chrome_path|
          megapixels = raster_dimensions.inject(&:*) / 1024.0 / 1024.0
          log_update "chrome: creating %i×%i (%.1fMpx) map raster at %i ppi"    % [*raster_dimensions, megapixels, options[:ppi]       ] if options[:ppi]
          log_update "chrome: creating %i×%i (%.1fMpx) map raster at %.1f m/px" % [*raster_dimensions, megapixels, options[:resolution]] if options[:resolution]

          render = lambda do |png_path|
            args = ["--window-size=#{PAGE},#{PAGE}", "--headless", "--screenshot=#{png_path}", "--disable-lcd-text", "--disable-extensions", "--hide-scrollbars", "--disable-gpu", "--force-color-profile=srgb"]
            FileUtils.rm png_path if png_path.exist?
            stdout, stderr, status = Open3.capture3 chrome_path.to_s, *args, "file://#{src_path}"
            raise "couldn't rasterise map using chrome" unless status.success? && png_path.file?
          end

          xml.elements["svg/@width" ].value.sub!(/^(.*)mm$/) { "%smm" % ($1.to_f * ppi / 96) }
          xml.elements["svg/@height"].value.sub!(/^(.*)mm$/) { "%smm" % ($1.to_f * ppi / 96) }

          src_path.write %Q[<?xml version='1.0' encoding='UTF-8'?><svg version='1.1' baseProfile='full' xmlns='http://www.w3.org/2000/svg'></svg>]
          empty_path = temp_dir / "empty.png"
          render.call empty_path
          json = OS.gdalinfo "-json", empty_path
          page = JSON.parse(json)["size"][0]

          origin, svg_dimensions = *xml.elements["svg/@viewBox"].value.split.map(&:to_f).each_slice(2)

          viewport_dimensions = svg_dimensions.map do |dimension|
            dimension * page / PAGE
          end

          svg_dimensions.map do |dimension|
            (dimension * ppi / 25.4 / page).ceil.times.map do |index|
              [index * page, index * page * 25.4 / ppi]
            end
          end.inject(&:product).map(&:transpose).map do |raster_offset, viewport_offset|
            page_path = temp_dir.join("page.%i.%i.png" % raster_offset)
            xml.elements["svg"].add_attribute "viewBox", [*viewport_offset, *viewport_dimensions].join(?\s)
            src_path.write xml
            render.call page_path
            REXML::Document.new(OS.gdal_translate "-of", "VRT", page_path, "/vsistdout/").tap do |vrt|
              vrt.elements.each("VRTDataset/VRTRasterBand[@band='4']", &:remove)
              vrt.elements.each("VRTDataset/VRTRasterBand/SimpleSource/DstRect") do |dst_rect|
                dst_rect.add_attributes "xOff" => raster_offset[0], "yOff" => raster_offset[1]
              end
            end
          end.inject do |vrt, page_vrt|
            vrt.elements["VRTDataset/VRTRasterBand[@band='1']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='1']/SimpleSource"]
            vrt.elements["VRTDataset/VRTRasterBand[@band='2']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='2']/SimpleSource"]
            vrt.elements["VRTDataset/VRTRasterBand[@band='3']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='3']/SimpleSource"]
            vrt
          end.tap do |vrt|
            vrt.elements["VRTDataset"].add_attributes "rasterXSize" => raster_dimensions[0], "rasterYSize" => raster_dimensions[1]
            File.write vrt_path, vrt
            OS.gdal_translate vrt_path, png_path
          end
        end
      end
    end
  end
end

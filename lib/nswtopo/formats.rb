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
    PAGE = 2048
    CHROME_ARGS = %W[--window-size=#{PAGE},#{PAGE} --headless --force-device-scale-factor=1 --disable-lcd-text --disable-extensions --hide-scrollbars --disable-gpu --force-color-profile=srgb]

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

    def rasterise(png_path, external:, background:, ppi: nil, **options)
      Dir.mktmppath do |temp_dir|
        svg_path = temp_dir / "map.svg"
        src_path = temp_dir / "browser.svg"
        vrt_path = temp_dir / "map.vrt"

        chrome_path = Config["chrome"]
        raise "please configure a path for google chrome" unless chrome_path

        render_svg svg_path, external: external, background: background
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

        megapixels = raster_dimensions.inject(&:*) / 1024.0 / 1024.0
        if options[:resolution]
          log_update "chrome: creating %i×%i (%.1fMpx) map raster at %.1f m/px" % [*raster_dimensions, megapixels, resolution]
        else
          log_update "chrome: creating %i×%i (%.1fMpx) map raster at %i ppi"    % [*raster_dimensions, megapixels, ppi]
        end

        xml.elements["svg/@width" ].value.sub!(/^(.*)mm$/) { "%smm" % ($1.to_f * ppi / 96) }
        xml.elements["svg/@height"].value.sub!(/^(.*)mm$/) { "%smm" % ($1.to_f * ppi / 96) }

        viewport_dimensions = xml.elements["svg/@viewBox"].value.split.map(&:to_f).last(2)
        viewport_dimensions.map do |dimension|
          (0...(dimension * ppi / 25.4).ceil).step(PAGE).map do |px|
            [px, px * 25.4 / ppi]
          end
        end.inject(&:product).map(&:transpose).map do |raster_offset, viewport_offset|
          page_path = temp_dir.join("page.%i.%i.png" % raster_offset)
          xml.elements["svg"].add_attribute "viewBox", [*viewport_offset, *viewport_dimensions].join(?\s)
          src_path.write xml

          chrome_args = %W[--screenshot=#{page_path} file://#{src_path}]
          stdout, stderr, status = Open3.capture3 chrome_path, *CHROME_ARGS, *chrome_args
          raise "couldn't rasterise map using chrome" unless status.success? && page_path.file?

          REXML::Document.new(OS.gdal_translate "-of", "VRT", page_path, "/vsistdout/").tap do |vrt|
            vrt.elements.each("VRTDataset/VRTRasterBand[@band='4']", &:remove)
            vrt.elements.each("VRTDataset/VRTRasterBand/SimpleSource/DstRect") do |dst_rect|
              dst_rect.add_attributes "xOff" => raster_offset[0], "yOff" => raster_offset[1]
            end
          end
        rescue Errno::ENOENT
          raise "invalid chrome path: %s" % chrome_path
        end.inject do |vrt, page_vrt|
          vrt.elements["VRTDataset/VRTRasterBand[@band='1']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='1']/SimpleSource"]
          vrt.elements["VRTDataset/VRTRasterBand[@band='2']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='2']/SimpleSource"]
          vrt.elements["VRTDataset/VRTRasterBand[@band='3']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='3']/SimpleSource"]
          vrt
        end.tap do |vrt|
          vrt.elements.each("VRTDataset/VRTRasterBand/@blockYSize", &:remove)
          vrt.elements.each("VRTDataset/Metadata", &:remove)
          vrt.elements["VRTDataset"].add_attributes "rasterXSize" => raster_dimensions[0], "rasterYSize" => raster_dimensions[1]
          File.write vrt_path, vrt
          OS.gdal_translate vrt_path, png_path
        end
      end
    end
  end
end

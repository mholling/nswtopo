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

    def self.extensions
      instance_methods.grep(/^render_([a-z]+)/) { $1 }
    end

    def self.===(ext)
      extensions.any? ext
    end

    def render_png(png_path, ppi: PPI, dither: false, **options)
      ppm = (ppi / 0.0254).round
      OS.exiftool yield(ppi: ppi, dither: dither),
        "-PNG:PixelsPerUnitX=#{ppm}",
        "-PNG:PixelsPerUnitY=#{ppm}",
        "-o", png_path
    rescue OS::Missing
      FileUtils.cp yield(ppi: ppi, dither: dither), png_path
    end

    def render_tif(tif_path, ppi: PPI, dither: false, **options)
      OS.gdal_translate yield(ppi: ppi, dither: dither),
        "-of", "GTiff",
        "-co", "COMPRESS=DEFLATE",
        "-co", "ZLEVEL=9",
        "-mo", "TIFFTAG_XRESOLUTION=#{ppi}",
        "-mo", "TIFFTAG_YRESOLUTION=#{ppi}",
        "-mo", "TIFFTAG_RESOLUTIONUNIT=2",
        tif_path
    end

    def render_jpg(jpg_path, ppi: PPI, **options)
      OS.gdal_translate yield(ppi: ppi),
        "-of", "JPEG",
        "-co", "QUALITY=90",
        "-mo", "EXIF_XResolution=#{ppi}",
        "-mo", "EXIF_YResolution=#{ppi}",
        "-mo", "EXIF_ResolutionUnit=2",
        jpg_path
    end

    def rasterise(png_path, background:, ppi: nil, resolution: nil)
      Dir.mktmppath do |temp_dir|
        svg_path = temp_dir / "map.svg"
        vrt_path = temp_dir / "map.vrt"
        render_svg svg_path, background: background

        case
        when ppi
          info = "%i ppi" % ppi
          mm_per_px = 25.4 / ppi
        when resolution
          ppi = 0.0254 * @scale / resolution
          info = "%.1f m/px" % resolution
          mm_per_px = to_mm(resolution)
        end

        raster_size = (@dimensions / mm_per_px).map(&:ceil)
        megapixels = raster_size.inject(&:*) / 1024.0 / 1024.0
        log_update "chrome: creating %i×%i (%.1fMpx) map raster at %s" % [*raster_size, megapixels, info]

        viewport_size = [PAGE * mm_per_px] * 2
        page_size = PAGE * mm_per_px * ppi / 96.0

        chrome = Ferrum::Browser.new(
          browser_path: Config["chrome"],
          window_size: [PAGE, PAGE],
          browser_options: {
            "force-device-scale-factor" => 1,
            "disable-lcd-text" => nil,
            "hide-scrollbars" => nil,
            "disable-gpu" => nil,
            "force-color-profile" => "srgb",
            # "default-background-color" => "00000000"
          }
        )
        chrome.goto "file://#{svg_path}"

        chrome.evaluate %Q[document.documentElement.setAttribute("width",  "#{page_size}mm")]
        chrome.evaluate %Q[document.documentElement.setAttribute("height", "#{page_size}mm")]

        chrome.evaluate(%Q[document.documentElement.getAttribute("viewBox")]).split.map(&:to_f).last(2).map do |mm|
          (0...(mm / mm_per_px).ceil).step(PAGE).map do |px|
            [px, px * mm_per_px]
          end
        end.inject(&:product).map(&:transpose).map do |raster_offset, viewport_offset|
          page_path = temp_dir.join("page.%i.%i.png" % raster_offset)
          viewbox = [*viewport_offset, *viewport_size].join(?\s)
          chrome.evaluate %Q[document.documentElement.setAttribute("viewBox", "#{viewbox}")]
          chrome.screenshot path: page_path

          REXML::Document.new(OS.gdal_translate "-of", "VRT", page_path, "/vsistdout/").tap do |vrt|
            vrt.elements.each("VRTDataset/VRTRasterBand/SimpleSource/DstRect") do |dst_rect|
              dst_rect.add_attributes "xOff" => raster_offset[0], "yOff" => raster_offset[1]
            end
          end
        end.inject do |vrt, page_vrt|
          vrt.elements["VRTDataset/VRTRasterBand[@band='1']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='1']/SimpleSource"]
          vrt.elements["VRTDataset/VRTRasterBand[@band='2']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='2']/SimpleSource"]
          vrt.elements["VRTDataset/VRTRasterBand[@band='3']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='3']/SimpleSource"]
          vrt.elements["VRTDataset/VRTRasterBand[@band='4']"].add_element page_vrt.elements["VRTDataset/VRTRasterBand[@band='4']/SimpleSource"]
          vrt
        end.tap do |vrt|
          vrt.elements.each("VRTDataset/VRTRasterBand/@blockYSize", &:remove)
          vrt.elements.each("VRTDataset/Metadata", &:remove)
          vrt.elements["VRTDataset"].add_attributes "rasterXSize" => raster_size[0], "rasterYSize" => raster_size[1]
          File.write vrt_path, vrt
          OS.gdal_translate vrt_path, png_path
        end
      rescue Ferrum::Error, SystemCallError
        log_abort "problem running chrome"
      end
    end
  end
end

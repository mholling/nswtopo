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
    TILE = 1500

    def self.extensions
      instance_methods.grep(/^render_([a-z]+)/) { $1 }
    end

    def self.===(ext)
      extensions.any? ext
    end

    def render_png(png_path, ppi: PPI, dither: false, **options)
      ppm = (ppi / 0.0254).round
      OS.exiftool yield(ppi: ppi, dither: dither), *%W[
        -PNG:PixelsPerUnitX=#{ppm}
        -PNG:PixelsPerUnitY=#{ppm}
        -o #{png_path}
      ]
    rescue OS::Missing
      FileUtils.cp yield(ppi: ppi, dither: dither), png_path
    end

    def render_tif(tif_path, ppi: PPI, dither: false, **options)
      OS.gdal_translate yield(ppi: ppi, dither: dither), *%W[
        -of GTiff
        -co COMPRESS=DEFLATE
        -co ZLEVEL=9
        -mo TIFFTAG_XRESOLUTION=#{ppi}
        -mo TIFFTAG_YRESOLUTION=#{ppi}
        -mo TIFFTAG_RESOLUTIONUNIT=2
      ], tif_path
    end

    def render_jpg(jpg_path, ppi: PPI, **options)
      OS.gdal_translate yield(ppi: ppi), *%W[
        -of JPEG
        -co QUALITY=90
        -mo EXIF_XResolution=#{ppi}
        -mo EXIF_YResolution=#{ppi}
        -mo EXIF_ResolutionUnit=2
      ], jpg_path
    end

    def rasterise(png_path, background:, ppi: nil, resolution: nil)
      Dir.mktmppath do |temp_dir|
        svg_path = temp_dir / "map.svg"
        vrt_path = temp_dir / "map.vrt"
        render_svg svg_path, background: background

        case
        when ppi
          ppi_info = "%i ppi" % ppi
          mm_per_px = 25.4 / ppi
        when resolution
          ppi_info = "%.1f m/px" % resolution
          mm_per_px = to_mm(resolution)
        end

        raster_size = (@dimensions / mm_per_px).map(&:ceil)
        megapixels = raster_size.inject(&:*) / 1024.0 / 1024.0

        raster_info = "%i×%i (%.1fMpx) map raster at %s" % [*raster_size, megapixels, ppi_info]
        chrome_message = "chrome: creating #{raster_info}"
        log_update chrome_message

        NSWTopo::Chrome.with_browser("--window-size=#{TILE},#{TILE}", "--force-gpu-mem-available-mb=4096", "file://#{svg_path}") do |browser|
          tile = browser.command("Page.getLayoutMetrics").fetch("cssLayoutViewport").values_at("clientWidth", "clientHeight")
          viewport_size = tile.times(mm_per_px)
          width, height = tile.times(25.4 / 96)

          browser.command "Emulation.setDefaultBackgroundColorOverride", color: { r: 0, g: 0, b: 0, a: 0 }
          browser.evaluate %Q[document.documentElement.setAttribute("width","#{width}mm")]
          browser.evaluate %Q[document.documentElement.setAttribute("height","#{height}mm")]

          browser.evaluate(%Q[document.documentElement.getAttribute("viewBox")]).split.map(&:to_f).last(2).zip(tile).map do |mm, tile|
            (0...(mm / mm_per_px).ceil).step(tile).map do |px|
              [px, px * mm_per_px]
            end
          end.inject(&:product).map(&:transpose).tap do |grid|
            chrome_message += " (tile %i of #{grid.size})"
          end.map.with_index do |(raster_offset, viewport_offset), index|
            log_update chrome_message % [index + 1]

            tile_path = temp_dir.join("tile.%i.%i.png" % raster_offset)
            viewbox = [*viewport_offset, *viewport_size].join(?\s)

            browser.evaluate %Q[document.documentElement.setAttribute("viewBox","#{viewbox}")]
            browser.screenshot tile_path

            REXML::Document.new(OS.gdal_translate "-of", "VRT", tile_path, "/vsistdout/").tap do |vrt|
              vrt.elements.each("VRTDataset/VRTRasterBand/SimpleSource/DstRect") do |dst_rect|
                dst_rect.add_attributes "xOff" => raster_offset[0], "yOff" => raster_offset[1]
              end
            end
          end.inject do |vrt, tile_vrt|
            vrt.elements["VRTDataset/VRTRasterBand[@band='1']"].add_element tile_vrt.elements["VRTDataset/VRTRasterBand[@band='1']/SimpleSource"]
            vrt.elements["VRTDataset/VRTRasterBand[@band='2']"].add_element tile_vrt.elements["VRTDataset/VRTRasterBand[@band='2']/SimpleSource"]
            vrt.elements["VRTDataset/VRTRasterBand[@band='3']"].add_element tile_vrt.elements["VRTDataset/VRTRasterBand[@band='3']/SimpleSource"]
            vrt.elements["VRTDataset/VRTRasterBand[@band='4']"].add_element tile_vrt.elements["VRTDataset/VRTRasterBand[@band='4']/SimpleSource"]
            vrt
          end.tap do |vrt|
            vrt.elements.each("VRTDataset/VRTRasterBand/@blockYSize", &:remove)
            vrt.elements.each("VRTDataset/Metadata", &:remove)
            vrt.elements["VRTDataset"].add_attributes "rasterXSize" => raster_size[0], "rasterYSize" => raster_size[1]
            File.write vrt_path, vrt
          end
        end

        log_update "nswtopo: finalising #{raster_info}"
        OS.gdal_translate vrt_path, png_path
      end
    end
  end
end

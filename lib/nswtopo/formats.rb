require_relative 'formats/svg'
require_relative 'formats/kmz'
require_relative 'formats/mbtiles'
require_relative 'formats/gemf'
require_relative 'formats/zip'
require_relative 'formats/pdf'
require_relative 'formats/svgz'

module NSWTopo
  module Formats
    using Helpers
    include Log

    PPI = 300
    TILE = 1500
    CHROME_ARGS = %w[--force-gpu-mem-available-mb=4096]
    CHROME_INSTANCES = (ThreadPool::CORES / 4).clamp(1, 6)

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

        viewport_size = [TILE * mm_per_px] * 2
        raster_size = @dimensions.map { |dimension| (dimension / mm_per_px).ceil }
        megapixels = raster_size.inject(&:*) / 1024.0 / 1024.0

        raster_info = "%i×%i (%.1fMpx) map raster at %s" % [*raster_size, megapixels, ppi_info]
        log_update "chrome: creating #{raster_info}"

        raster_size.map do |px|
          (0...px).step(TILE).map do |px|
            [px, px * mm_per_px]
          end
        end.inject(&:product).map(&:transpose).map do |raster_offset, viewport_offset|
          next raster_offset, viewport_offset, temp_dir.join("tile.%i.%i.png" % raster_offset)
        end.inject(ThreadPool.new(CHROME_INSTANCES), &:<<).in_groups do |*grid|
          NSWTopo::Chrome.with_browser "file://#{svg_path}", width: TILE, height: TILE, args: CHROME_ARGS do |browser|
            svg = browser.query_selector "svg"
            svg[:width], svg[:height] = nil, nil
            grid.each do |raster_offset, viewport_offset, tile_path|
              svg[:viewBox] = [*viewport_offset, *viewport_size].join(?\s)
              browser.screenshot tile_path
            end
          end
        end.map do |raster_offset, viewport_offset, tile_path|
          REXML::Document.new(OS.gdal_translate "-of", "VRT", tile_path, "/vsistdout/").tap do |vrt|
            vrt.elements.each("VRTDataset/VRTRasterBand/SimpleSource/DstRect") do |dst_rect|
              dst_rect.add_attributes "xOff" => raster_offset[0], "yOff" => raster_offset[1]
            end
            vrt.elements["VRTDataset/VRTRasterBand[@band='1']"].deep_clone.then do |band|
              vrt.elements["VRTDataset"].add_element(band)
              band.add_attribute("band", 4)
              band.elements["ColorInterp"].text = "Alpha"
              band.elements["SimpleSource"]
            end.then do |source|
              source.name = "ComplexSource"
              source.add_element("ScaleRatio").add_text("0")
              source.add_element("ScaleOffset").add_text("255")
            end unless vrt.elements["VRTDataset/VRTRasterBand[@band='4']"]
          end
        end.inject do |vrt, tile_vrt|
          vrt.elements["VRTDataset/VRTRasterBand[@band='1']"].add_element tile_vrt.elements["VRTDataset/VRTRasterBand[@band='1']/SimpleSource"]
          vrt.elements["VRTDataset/VRTRasterBand[@band='2']"].add_element tile_vrt.elements["VRTDataset/VRTRasterBand[@band='2']/SimpleSource"]
          vrt.elements["VRTDataset/VRTRasterBand[@band='3']"].add_element tile_vrt.elements["VRTDataset/VRTRasterBand[@band='3']/SimpleSource"]
          vrt.elements["VRTDataset/VRTRasterBand[@band='4']"].add_element tile_vrt.elements["VRTDataset/VRTRasterBand[@band='4']/*[self::SimpleSource|self::ComplexSource]"]
          vrt
        end.tap do |vrt|
          vrt.elements.each("VRTDataset/VRTRasterBand/@blockYSize", &:remove)
          vrt.elements.each("VRTDataset/Metadata", &:remove)
          vrt.elements["VRTDataset"].add_attributes "rasterXSize" => raster_size[0], "rasterYSize" => raster_size[1]
          File.write vrt_path, vrt
        end

        log_update "nswtopo: finalising #{raster_info}"
        OS.gdal_translate vrt_path, png_path
      end
    end
  end
end

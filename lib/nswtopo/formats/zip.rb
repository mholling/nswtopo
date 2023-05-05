module NSWTopo
  module Formats
    def render_zip(zip_path, name:, ppi: PPI, **options)
      Dir.mktmppath do |temp_dir|
        zip_dir = temp_dir.join("zip").tap(&:mkpath)
        tiles_dir = zip_dir.join("tiles").tap(&:mkpath)
        png_path = yield(ppi: ppi)

        2.downto(0).map.with_index do |level, index|
          mm_per_px = 25.4 * 2**index / ppi
          dimensions = (@dimensions / mm_per_px).map(&:ceil)
          case index
          when 0
            outsize = dimensions.inject(&:<) ? [0, 64] : [64, 0]
            OS.gdal_translate *%w[--config GDAL_PAM_ENABLED NO -r bilinear -outsize], *outsize, png_path, zip_dir / "thumb.png"
          when 1
            zip_dir.join("#{name}.ref").open("w") do |file|
              file.puts @projection.wkt2
              file.puts [0.0, mm_per_px, 0.0, @dimensions[1], 0.0, -mm_per_px].join(?,)
              file << dimensions.join(?,)
            end
          end
          img_path = index.zero? ? png_path : temp_dir / "map.#{level}.png"
          next level, dimensions, img_path
        end.each.concurrently do |level, dimensions, img_path|
          OS.gdal_translate *%w[-r bicubic -outsize], *dimensions, png_path, img_path unless img_path.exist?
        end.flat_map do |level, dimensions, img_path|
          dimensions.map do |dimension|
            (0...dimension).step(256).with_index.entries
          end.inject(&:product).map do |(col, j), (row, i)|
            tile_path = tiles_dir / "#{level}x#{i}x#{j}.png"
            size = [-col, -row].zip(dimensions).map(&:sum).zip([256, 256]).map(&:min)
            %w[--config GDAL_PAM_ENABLED NO -srcwin] + [col, row, *size, img_path, tile_path]
          end
        end.tap do |tiles|
          log_update "zip: creating %i tiles" % tiles.length
        end.each.concurrently do |args|
          OS.gdal_translate *args
        end.map(&:last).tap do |tile_paths|
          log_update "zip: optimising %i tiles" % tile_paths.length
        end.each.concurrent_groups do |tile_paths|
          dither *tile_paths
        rescue Dither::Missing
        end

        zip zip_dir, zip_path
      end
    end
  end
end

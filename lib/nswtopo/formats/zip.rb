module NSWTopo
  module Formats
    using Helpers
    def render_zip(zip_path, name:, ppi: PPI, **options)
      Dir.mktmppath do |temp_dir|
        zip_dir = temp_dir.join("zip").tap(&:mkpath)
        tiles_dir = zip_dir.join("tiles").tap(&:mkpath)
        png_path = yield(ppi: ppi)

        2.downto(0).map.with_index do |level, index|
          geo_transform = geotransform(ppi: ppi / 2**index)
          outsize = @dimensions.map { |dimension| (dimension / geo_transform[1]).ceil }
          case index
          when 0
            thumb_size = outsize.inject(&:<) ? [0, 64] : [64, 0]
            OS.gdal_translate *%w[--config GDAL_PAM_ENABLED NO -r bilinear -outsize], *thumb_size, png_path, zip_dir / "thumb.png"
          when 1
            zip_dir.join("#{name}.ref").open("w") do |file|
              file.puts @projection.wkt2
              file.puts geo_transform.join(?,)
              file.puts outsize.join(?,)
            end
          end
          img_path = index.zero? ? png_path : temp_dir / "map.#{level}.png"
          next level, outsize, img_path
        end.inject(ThreadPool.new, &:<<).each do |level, outsize, img_path|
          OS.gdal_translate *%w[-r bicubic -outsize], *outsize, png_path, img_path unless img_path.exist?
        end.flat_map do |level, outsize, img_path|
          outsize.map do |px|
            (0...px).step(256).with_index.entries
          end.inject(&:product).map do |(col, j), (row, i)|
            tile_path = tiles_dir / "#{level}x#{i}x#{j}.png"
            size = [-col, -row].zip(outsize).map(&:sum).zip([256, 256]).map(&:min)
            %w[--config GDAL_PAM_ENABLED NO -srcwin] + [col, row, *size, img_path, tile_path]
          end
        end.tap do |tiles|
          log_update "zip: creating %i tiles" % tiles.length
        end.inject(ThreadPool.new, &:<<).each do |*args|
          OS.gdal_translate *args
        end.map(&:last).tap do |tile_paths|
          log_update "zip: optimising %i tiles" % tile_paths.length
        end.inject(ThreadPool.new, &:<<).in_groups do |*tile_paths|
          dither *tile_paths
        rescue Dither::Missing
        end

        zip zip_dir, zip_path
      end
    end
  end
end

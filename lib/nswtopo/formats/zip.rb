module NSWTopo
  module Formats
    def render_zip(zip_path, name:, ppi: PPI, **options)
      Dir.mktmppath do |temp_dir|
        zip_dir = temp_dir.join("#{name}.avenza").tap(&:mkpath)
        tiles_dir = zip_dir.join("tiles").tap(&:mkpath)
        png_path = yield(ppi: ppi)
        top_left = bounding_box.coordinates[0][3]

        2.downto(0).map.with_index do |level, index|
          [level, index, ppi.to_f / 2**index]
        end.each.concurrently do |level, index, ppi|
          dimensions, ppi, resolution = raster_dimensions_at ppi: ppi
          img_path = index.zero? ? png_path : temp_dir / "#{name}.avenza.#{level}.png"
          tile_path = temp_dir.join("#{name}.avenza.tile.#{level}.%09d.png").to_s

          OS.convert png_path, "-filter", "Lanczos", "-resize", "%ix%i!" % dimensions, img_path unless img_path.exist?
          OS.convert img_path, "+repage", "-crop", "256x256", tile_path

          dimensions.reverse.map do |dimension|
            0.upto((dimension - 1) / 256).to_a
          end.inject(&:product).each.with_index do |(y, x), n|
            FileUtils.cp tile_path % n, tiles_dir / "#{level}x#{y}x#{x}.png"
          end
          zip_dir.join("#{name}.ref").open("w") do |file|
            file.puts @projection.wkt_simple
            file.puts WorldFile.geotransform(top_left, resolution, -@rotation).flatten.join(?,)
            file << dimensions.join(?,)
          end if index == 1
        end
        Pathname.glob(tiles_dir / "*.png").each.concurrent_groups do |tile_paths|
          dither *tile_paths
        end

        OS.convert png_path, "-thumbnail", "64x64", "-gravity", "center", "-background", "white", "-extent", "64x64", "-alpha", "Remove", "-type", "TrueColor", zip_dir / "thumb.png"
        zip zip_dir, zip_path
      end
    end
  end
end

module NSWTopo
  module Avenza
    extend Dither
    LEVELS = 3 # TODO: determine programmatically, or is this fixed?
    
    def self.build(config, map, ppi, png_path, temp_dir, zip_path)
      zip_dir = temp_dir + map.name
      tiles_dir = zip_dir + "tiles"
      tiles_dir.mkpath
      
      (LEVELS - 1).downto(0).map.with_index do |level, index|
        [ level, index, ppi.to_f / 2**index ]
      end.each.in_parallel do |level, index, ppi|
        dimensions = map.dimensions_at ppi
        img_path = index.zero? ? png_path : temp_dir + "avenza.#{level}.png"
        tile_path = temp_dir.join("avenza.tile.#{level}.%09d.png").to_s
        %x[convert "#{png_path}" -filter Lanczos -resize #{dimensions.join ?x}! "#{img_path}"] unless img_path.exist?
        %x[convert "#{img_path}" +repage -crop 256x256 "#{tile_path}"]
        dimensions.reverse.map do |dimension|
          0.upto((dimension - 1) / 256).to_a
        end.inject(&:product).each.with_index do |(y, x), n|
          FileUtils.cp tile_path % n, tiles_dir + "#{level}x#{y}x#{x}.png"
        end
        zip_dir.join("#{map.name}.ref").open("w") do |file|
          file.puts map.projection.wkt_simple
          file.puts map.geotransform_at(ppi).flatten.join(?,)
          file << dimensions.join(?,)
        end if index == 1
      end
      Pathname.glob(tiles_dir + "*.png").each.in_parallel_groups do |tile_paths|
        dither config, *tile_paths
      end
      
      %x[convert "#{png_path}" -thumbnail 64x64 -gravity center -background white -extent 64x64 -alpha Remove -type TrueColor "#{zip_dir + 'thumb.png'}"]
      
      Dir.chdir(zip_dir) { %x[#{ZIP} -r "#{zip_path}" *] }
    end
  end
end
module NSWTopo
  module MBTiles
    RESOLUTION, ORIGIN, TILE_SIZE = 2 * 78271.516, -20037508.34, 256
    METERS_PER_INCH = 0.0254
    def self.build(config, map, ppi, svg_path, temp_dir, mbt_path)
      sql = %Q[
        CREATE TABLE metadata (name TEXT, value TEXT);
        INSERT INTO metadata VALUES ("name", "#{map.name}");
        INSERT INTO metadata VALUES ("type", "baselayer");
        INSERT INTO metadata VALUES ("version", "1.1");
        INSERT INTO metadata VALUES ("description", "#{map.name}");
        INSERT INTO metadata VALUES ("format", "png");
        INSERT INTO metadata VALUES ("bounds", "#{map.wgs84_bounds.flatten.values_at(0,2,1,3).join ?,}");
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
      ]
      commands = []
      cosine = Math::cos(map.wgs84_bounds.last.mean * Math::PI / 180)
      bounds = map.transform_bounds_to(Projection.new "EPSG:3857")
      png_path = temp_dir + "#{map.name}.mbtiles.png"
      pgw_path = temp_dir + "#{map.name}.mbtiles.pgw"
      (ppi <= 25 ? ppi : Math::log2(RESOLUTION * ppi * cosine / METERS_PER_INCH / map.scale).ceil).downto(0).map do |zoom|
        [ zoom, RESOLUTION / (2 ** zoom) ]
      end.tap do |(zoom, resolution), *|
        ppi = METERS_PER_INCH * map.scale / resolution / cosine
        dimensions = map.dimensions_at ppi
        puts "  Generating raster: %ix%i (%.1fMpx)" % [ *dimensions, 0.000001 * dimensions.inject(:*) ]
        Raster.build config, map, ppi, svg_path, temp_dir, png_path
        map.write_world_file pgw_path, map.resolution_at(ppi)
      end.each.with_index do |(zoom, resolution), index|
        $stdout << "\r  Reprojecting for zoom level %s" % (zoom + index).downto(zoom).to_a.join(', ')
        tif_path, tfw_path = %w[tif tfw].map { |ext| temp_dir + "#{map.name}.mbtiles.#{zoom}.#{ext}" }
        indices, dimensions, topleft = bounds.map do |lower, upper|
          ((lower - ORIGIN) / resolution / TILE_SIZE).floor ... ((upper - ORIGIN) / resolution / TILE_SIZE).ceil
        end.map.with_index do |indices, axis|
          [ indices, (indices.last - indices.first) * TILE_SIZE, ORIGIN + (axis.zero? ? indices.first : indices.last) * TILE_SIZE * resolution]
        end.transpose
        WorldFile.write topleft, resolution, 0, tfw_path
        %x[convert -size #{dimensions.join ?x} canvas:none -type TrueColorAlpha -depth 8 "#{tif_path}"]
        %x[gdalwarp -s_srs "#{map.projection}" -t_srs EPSG:3857 -r bilinear -dstalpha "#{png_path}" "#{tif_path}"]
        indices.map(&:each).map(&:with_index).map(&:to_a).inject(&:product).each do |(col, x), (row, y)|
          tile_path = temp_dir + "#{map.name}.mbtiles.#{zoom}.#{col}.#{row}.png"
          # TODO: check for transparent tile (e.g. for rotated map) and don't include the tile if so
          commands << %Q[convert "#{tif_path}" -quiet +repage -gravity SouthWest -crop #{TILE_SIZE}x#{TILE_SIZE}+#{x * TILE_SIZE}+#{y * TILE_SIZE} "#{tile_path}"]
          sql << %Q[INSERT INTO tiles VALUES (#{zoom}, #{col}, #{row}, readfile("#{tile_path}"));\n]
        end
        break if indices.map(&:count).all? { |count| count < 3 }
      end.tap { puts }
      commands.each.with_index do |command, index|
        $stdout << "\r  Tiling: #{index} of #{commands.length}"
        system command
      end.tap { puts }
      temp_dir.join("mbtiles.sql").tap do |sql_path|
        sql_path.write sql
        %x[echo .exit | sqlite3 -init "#{sql_path}" "#{mbt_path}"]
      end
    end
  end
end

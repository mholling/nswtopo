module NSWTopo
  module Formats
    def render_mbtiles(mbtiles_path, name:, **options, &block)
      wgs84_bounds = bounds(projection: Projection.wgs84)
      sql = <<~SQL
        CREATE TABLE metadata (name TEXT, value TEXT);
        INSERT INTO metadata VALUES ("name", "#{name}");
        INSERT INTO metadata VALUES ("type", "baselayer");
        INSERT INTO metadata VALUES ("version", "1.1");
        INSERT INTO metadata VALUES ("description", "#{name}");
        INSERT INTO metadata VALUES ("format", "png");
        INSERT INTO metadata VALUES ("bounds", "#{wgs84_bounds.transpose.flatten.join ?,}");
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
      SQL

      Dir.mktmppath do |temp_dir|
        tiled_web_map(temp_dir, **options, extension: "mbtiles", &block).each do |zoom, col, row, tile_path|
          sql << %Q[INSERT INTO tiles VALUES (#{zoom}, #{col}, #{row}, readfile("#{tile_path}"));\n]
        end

        OS.sqlite3 mbtiles_path do |stdin|
          stdin.puts sql
          stdin.puts ".exit"
        end
      end
    end
  end
end

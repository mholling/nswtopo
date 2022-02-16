module NSWTopo
  module Formats
    def render_gemf(gemf_path, name:, **options, &block)
      Dir.mktmppath do |temp_dir|
        ranges = tiled_web_map(temp_dir, **options, extension: "gemf", &block).sort_by do |tile|
          tile.values_at :col, :row
        end.group_by do |zoom:, **|
          zoom
        end

        header, source = "", "nswtopo"
        # 3.1 overall header:
        header << [4, 256].pack("L>L>")
        # 3.2 sources:
        header << [1, 0, source.bytesize, source].pack("L>L>L>a#{source.bytesize}")
        # 3.3 number of ranges:
        header << [ranges.length].pack("L>")

        offset = header.bytesize + ranges.size * 32
        ranges.each do |zoom, tiles|
          cols, rows = tiles.map do |tile|
            tile.values_at :col, :row
          end.transpose
          # 3.3 range data:
          header << [zoom, *cols.minmax, *rows.minmax, 0, offset].pack("L>L>L>L>L>L>Q>")
          offset += tiles.size * 12
        end.each do |zoom, tiles|
          # 3.4 range details:
          tiles.each do |tile_path:, **|
            header << [offset, tile_path.size].pack("Q>L>")
            offset += tile_path.size
          end
        end.values.flatten.map do |tile_path:, **|
          tile_path
        end.tap do |tile_paths|
          gemf_path.open("wb") do |file|
            file.write header
            # 4 data area:
            tile_paths.each do |tile_path|
              file.write tile_path.binread
            end
          end
        end
      end
    end
  end
end

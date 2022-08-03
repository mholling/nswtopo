module NSWTopo
  module TiledWebMap
    HALF, TILE_SIZE, DEFAULT_ZOOM = Math::PI * 6378137, 256, 16

    def tiled_web_map(temp_dir, extension:, zoom: [DEFAULT_ZOOM], **options, &block)
      web_mercator_bounds = bounds(projection: Projection.new("EPSG:3857"))
      wgs84_bounds = bounds(projection: Projection.wgs84)

      png_path = nil
      max_zoom, min_zoom = *zoom.sort.reverse
      max_zoom.downto(0).map do |zoom|
        indices, ts = web_mercator_bounds.map do |lower, upper|
          (2**zoom * (lower + HALF) / HALF / 2).floor ... (2**zoom * (upper + HALF) / HALF / 2).ceil
        end.map do |indices|
          [indices, indices.size * TILE_SIZE]
        end.transpose
        te = [*indices.map(&:begin), *indices.map(&:end)].map do |index|
          index * 2 * HALF / 2**zoom - HALF
        end
        resolution = 2 * HALF / TILE_SIZE / 2**zoom
        tif_path = temp_dir / "tile.#{zoom}.tif"
        { resolution: resolution, ts: ts, te: te, tif_path: tif_path, indices: indices, zoom: zoom }
      end.select do |indices:, zoom:, **|
        next true if zoom == max_zoom
        next zoom >= min_zoom if min_zoom
        !indices.all?(&:one?)
      end.tap do |max_level, *|
        png_path = yield(max_level.slice :resolution)
      end.tap do |levels|
        zoom_levels = levels.map { |zoom:, **| zoom }
        log_update "#{extension}: creating zoom levels %s" % zoom_levels.minmax.uniq.join(?-)
      end.each.concurrently do |ts:, te:, tif_path:, **|
        OS.gdalwarp "-s_srs", @projection, "-t_srs", "EPSG:3857", "-ts", *ts, "-te", *te, "-r", "cubic", "-dstalpha", png_path, tif_path
      end.flat_map do |tif_path:, indices:, zoom:, **|
        cols, rows = indices.map(&:to_a)
        [cols, rows.reverse].map(&:each).map(&:with_index).map(&:entries).inject(&:product).map do |(col, j), (row, i)|
          row ^= 2**zoom - 1 if extension == "gemf"
          tile_path = temp_dir / "tile.#{zoom}.#{col}.#{row}.png"
          args = ["-srcwin", j * TILE_SIZE, i * TILE_SIZE, TILE_SIZE, TILE_SIZE, tif_path, tile_path]
          { zoom: zoom, row: row, col: col, tile_path: tile_path, args: args}
        end
      end.tap do |tiles|
        log_update "#{extension}: creating %i tiles" % tiles.length
      end.each.concurrently do |args:, tile_path:, **|
        OS.gdal_translate *args
      end.map do |tiles|
        tiles.slice :zoom, :col, :row, :tile_path
      end.tap do |tiles|
        log_update "#{extension}: optimising %i tiles" % tiles.length
        tiles.map do |tile_path:, **|
          tile_path
        end.each.concurrent_groups do |png_paths|
          dither *png_paths
        rescue Dither::Missing
        end
      end
    end
  end
end

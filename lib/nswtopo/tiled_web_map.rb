module NSWTopo
  module TiledWebMap
    HALF, TILE_SIZE, DEFAULT_ZOOM = Math::PI * 6378137, 256, 16

    def tiled_web_map(temp_dir, extension:, zoom: [DEFAULT_ZOOM], **options, &block)
      web_mercator_bounds = @cutline.reproject_to(Projection.new("EPSG:3857")).bounds
      wgs84_bounds = @cutline.reproject_to_wgs84.bounds

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
        OpenStruct.new resolution: resolution, ts: ts, te: te, tif_path: tif_path, indices: indices, zoom: zoom
      end.select do |level|
        next true if level.zoom == max_zoom
        next level.zoom >= min_zoom if min_zoom
        !level.indices.all?(&:one?)
      end.tap do |max_level, *|
        png_path = yield(resolution: max_level.resolution)
      end.tap do |levels|
        log_update "#{extension}: creating zoom levels %s" % levels.map(&:zoom).minmax.uniq.join(?-)
      end.each.concurrently do |level|
        OS.gdalwarp "-t_srs", "EPSG:3857", "-ts", *level.ts, "-te", *level.te, "-r", "cubic", "-dstalpha", png_path, level.tif_path
      end.flat_map do |level|
        cols, rows = level.indices
        [cols.each, rows.reverse_each].map(&:with_index).map(&:entries).inject(&:product).map do |(col, j), (row, i)|
          row ^= 2**level.zoom - 1 if extension == "gemf"
          path = temp_dir / "tile.#{level.zoom}.#{col}.#{row}.png"
          args = ["-srcwin", j * TILE_SIZE, i * TILE_SIZE, TILE_SIZE, TILE_SIZE, level.tif_path, path]
          OpenStruct.new zoom: level.zoom, row: row, col: col, path: path, args: args
        end
      end.tap do |tiles|
        log_update "#{extension}: creating %i tiles" % tiles.length
      end.each.concurrently do |tile|
        OS.gdal_translate *tile.args
      end.entries.tap do |tiles|
        log_update "#{extension}: optimising %i tiles" % tiles.length
        tiles.map(&:path).each.concurrent_groups do |paths|
          dither *paths
        rescue Dither::Missing
        end
      end
    end
  end
end

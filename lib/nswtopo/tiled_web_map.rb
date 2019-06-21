module NSWTopo
  module TiledWebMap
    HALF, TILE_SIZE, DEFAULT_ZOOM = Math::PI * 6378137, 256, 16

    def tiled_web_map(temp_dir, extension:, zoom: DEFAULT_ZOOM, **options, &block)
      raise "invalid zoom outside 10-19 range: #{zoom}" unless (10..19) === zoom

      web_mercator_bounds = bounds(projection: Projection.new("EPSG:3857"))
      wgs84_bounds = bounds(projection: Projection.wgs84)

      png_path = nil
      zoom.downto(0).inject([]) do |levels, zoom|
        indices, dimensions, topleft = web_mercator_bounds.map do |lower, upper|
          (2**zoom * (lower + HALF) / HALF / 2).floor ... (2**zoom * (upper + HALF) / HALF / 2).ceil
        end.map.with_index do |indices, axis|
          [indices, indices.size * TILE_SIZE, (axis.zero? ? indices.first : indices.last) * 2 * HALF / 2**zoom - HALF]
        end.transpose
        tile_path = temp_dir.join("tile.#{zoom}.%09d.png").to_s
        resolution = 2 * HALF / TILE_SIZE / 2**zoom
        levels << [resolution, indices, dimensions, topleft, tile_path, zoom]
        break levels if indices.map(&:size).all? { |size| size < 3 }
        levels
      end.tap do |(resolution, *), *|
        png_path = yield(resolution: resolution)
      end.tap do |levels|
        log_update "#{extension}: tiling for zoom levels %s" % levels.map(&:last).minmax.uniq.join(?-)
      end.each.concurrently do |resolution, indices, dimensions, topleft, tile_path, zoom|
        tif_path, tfw_path = %w[tif tfw].map { |ext| temp_dir / "tile.#{zoom}.#{ext}" }
        WorldFile.write topleft, resolution, 0, tfw_path
        OS.convert "-size", dimensions.join(?x), "canvas:none", "-type", "TrueColorAlpha", "-depth", 8, tif_path
        OS.gdalwarp "-s_srs", @projection, "-t_srs", "EPSG:3857", "-r", "cubic", "-dstalpha", png_path, tif_path
        OS.convert tif_path, "-quiet", "+repage", "-crop", "#{TILE_SIZE}x#{TILE_SIZE}", tile_path
      end.map do |resolution, indices, dimensions, topleft, tile_path, zoom|
        cols, rows = indices.map(&:to_a)
        rows.reverse.product(cols).map.with_index do |(row, col), index|
          row ^= 2**zoom - 1 if extension == "gemf"
          [zoom, col, row, Pathname(tile_path % index)]
        end
      end.flatten(1).tap do |tiles|
        log_update "#{extension}: optimising %i tiles" % tiles.length
        tiles.map(&:last).each.concurrent_groups do |png_paths|
          dither *png_paths
        end
      end
    end
  end
end

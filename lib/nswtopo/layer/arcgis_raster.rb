module NSWTopo
  module ArcGISRaster
    include Raster, Log
    CREATE = %w[url]

    def get_raster(temp_dir)
      raise "no resolution specified for #{@name}" unless Numeric === @resolution
      txt_path = temp_dir / "mosaic.txt"
      vrt_path = temp_dir / "mosaic.vrt"

      ArcGISServer.start @url do |connection, service, projection|
        local_bbox = @map.bounding_box
        target_bbox = local_bbox.reproject_to projection
        target_resolution = @resolution * Math::sqrt(target_bbox.first.area / local_bbox.first.area)

        raise "not a tiled map or image server: #{@url}" unless tile_info = service["tileInfo"]
        lods = tile_info["lods"]
        origin = tile_info["origin"].values_at "x", "y"
        tile_sizes = tile_info.values_at "cols", "rows"

        lods.sort_by! do |lod|
          -lod["resolution"]
        end
        lod = lods.find do |lod|
          lod["resolution"] < target_resolution
        end || lods.last
        tile_level, tile_resolution = lod.values_at "level", "resolution"

        tiles = target_bbox.coordinates.first.map do |corner|
          corner.minus(origin)
        end.transpose.map(&:minmax).zip(tile_sizes).map do |bound, tile_size|
          bound / tile_resolution / tile_size
        end.map do |min, max|
          (min.floor..max.ceil).each_cons(2).to_a
        end.inject(&:product).map do |cols, rows|
          bounds = [cols, rows].zip(tile_sizes).map do |indices, tile_size|
            indices.times(tile_size * tile_resolution)
          end.transpose.map do |corner|
            corner.plus(origin)
          end.transpose

          bbox = bounds.inject(&:product).values_at(0,2,3,1)
          next unless target_bbox.first.clip(bbox)

          row, col = rows[1].abs, cols[0]
          rel_path = "tile/#{tile_level}/#{row}/#{col}"
          jpg_path = temp_dir / "#{row}.#{col}" # could be png
          tif_path = temp_dir / "#{row}.#{col}.tif"

          ullr = bounds.inject(&:product).values_at(1,2).flatten
          gdal_args = ["-a_srs", projection, "-a_ullr", *ullr, "-of", "GTiff", jpg_path, tif_path]

          [rel_path, jpg_path, gdal_args, tif_path]
        end.compact
        tiles.each.with_index do |(rel_path, jpg_path, gdal_args, tif_path), index|
          log_update "%s: retrieving tile %i of %i" % [@name, index + 1, tiles.length]
          connection.get(rel_path, blankTile: true) do |response|
            jpg_path.binwrite response.body
          end
        end
      end.each do |rel_path, jpg_path, gdal_args, tif_path|
        OS.gdal_translate *gdal_args
      end.map(&:last).tap do |tif_paths|
        txt_path.write tif_paths.join(?\n)
        OS.gdalbuildvrt "-input_file_list", txt_path, vrt_path
      end

      OS.gdal_translate vrt_path, Pathname.pwd / "foo.tif"

      return @resolution, vrt_path
    end
  end
end

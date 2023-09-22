module NSWTopo
  module ArcGISRaster
    include Raster, RasterRender, Log
    CREATE = %w[url]

    def get_raster(temp_dir)
      raise "no resolution specified for #{@name}" unless Numeric === @mm_per_px
      txt_path = temp_dir / "mosaic.txt"
      vrt_path = temp_dir / "mosaic.vrt"

      service = ArcGIS::Service.new @url
      local_bbox = @map.cutline.bbox
      target_bbox = local_bbox.reproject_to service.projection
      target_resolution = @mm_per_px * Math::sqrt(target_bbox.first.area / local_bbox.first.area)

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

      target_bbox.bounds.zip(origin, tile_sizes).map do |(min, max), origin, tile_size|
        [(min - origin) / tile_resolution / tile_size, (max - origin) / tile_resolution / tile_size]
      end.map do |min, max|
        (min.floor..max.ceil).each_cons(2).to_a
      end.inject(&:product).inject(GeoJSON::Collection.new(projection: service.projection)) do |tiles, (cols, rows)|
        [cols, rows].zip(tile_sizes).map do |indices, tile_size|
          indices.map { |index| index * tile_size * tile_resolution }
        end.transpose.map do |corner|
          Vector[*corner] + Vector[*origin]
        end.transpose.then do |bounds|
          ring = bounds.inject(&:product).values_at(0,2,3,1,0)
          ullr = bounds.inject(&:product).values_at(1,2).flatten
          row, col = rows[1].abs, cols[0]
          tiles.add_polygon [ring], ullr: ullr, row: row, col: col
        end
      end.clip(target_bbox.first).then do |tiles|
        tiles.map.with_index do |feature, index|
          row, col, ullr = feature.values_at("row", "col", "ullr")
          rel_path = "tile/#{tile_level}/#{row}/#{col}"
          jpg_path = temp_dir / "#{row}.#{col}" # could be png
          tif_path = temp_dir / "#{row}.#{col}.tif"
          gdal_args = ["-a_srs", service.projection, "-a_ullr", *ullr, "-of", "GTiff", jpg_path, tif_path]
          log_update "%s: retrieving tile %i of %i" % [@name, index + 1, tiles.length]
          service.get(rel_path, blankTile: true) do |response|
            jpg_path.binwrite response.body
          end
          OS.gdal_translate *gdal_args
          tif_path
        end
      end.tap do |tif_paths|
        log_update "%s: mosaicing %s tiles" % [@name, tif_paths.length] if tif_paths.length > 1
        txt_path.write tif_paths.join(?\n)
      end

      OS.gdalbuildvrt "-input_file_list", txt_path, vrt_path
      return vrt_path
    end
  end
end

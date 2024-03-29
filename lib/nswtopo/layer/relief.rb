module NSWTopo
  module Relief
    include Raster, MaskRender, DEM, Log
    CREATE = %w[method azimuth factor smooth contours epsg]
    DEFAULTS = YAML.load <<~YAML
      shade: rgb(0,0,48)
      method: combined
      azimuth: 315
      factor: 2.0
      smooth: 4
      opacity: 0.25
    YAML

    def margin
      { mm: 3 * @smooth }
    end

    def get_raster(temp_dir)
      cutline = @map.cutline(**margin)
      dem_path = temp_dir / "dem.tif"

      case
      when @path
        get_dem temp_dir, dem_path

      when @contours
        bounds = cutline.bounds
        raise "no resolution specified for #{@name}" unless Numeric === @mm_per_px
        outsize = bounds.map do |min, max|
          (max - min) / @mm_per_px
        end.map(&:ceil)

        collection = @contours.map do |url_or_path, attribute_or_hash|
          raise "no elevation attribute specified for #{url_or_path}" unless attribute_or_hash
          options   = Hash === attribute_or_hash ? attribute_or_hash.transform_keys(&:to_sym).slice(:where, :layer) : {}
          attribute = Hash === attribute_or_hash ? attribute_or_hash["attribute"] : attribute_or_hash
          case url_or_path
          when ArcGIS::Service
            layer = ArcGIS::Service.new(url_or_path).layer(**options, geometry: cutline)
            layer.features do |count, total|
              log_update "%s: retrieved %i of %i contours" % [@name, count, total]
            end
          when Shapefile::Source
            Shapefile::Source.new(url_or_path).layer(**options, geometry: cutline).features
          else
            raise "unrecognised elevation data source: #{url_or_path}"
          end.map! do |feature|
            feature.with_properties("elevation" => feature.fetch(attribute, attribute).to_f)
          end.reproject_to(@map.projection)
        end.inject(&:merge)

        log_update "%s: calculating DEM" % @name
        OS.gdal_grid "-a", "linear:radius=0:nodata=-9999", "-zfield", "elevation", "-ot", "Float32", "-txe", *bounds[0], "-tye", *bounds[1], "-outsize", *outsize, "GeoJSON:/vsistdin?buffer_limit=-1", dem_path do |stdin|
          stdin.puts collection.to_json
        end

      else
        raise "no elevation data specified for relief layer #{@name}"
      end

      raw_path = temp_dir / "relief.raw.tif"
      tif_path = temp_dir / "relief.tif"

      begin
        log_update "%s: generating shaded relief" % @name
        OS.gdaldem *%W[hillshade -q -compute_edges -s #{@map.scale / 1000.0} -z #{@factor} -az #{@azimuth} -#{@method}], dem_path, raw_path
        OS.gdalwarp "-t_srs", @map.projection, "-cutline", "GeoJSON:/vsistdin?buffer_limit=-1", "-crop_to_cutline", raw_path, tif_path do |stdin|
          stdin.puts cutline.to_json
        end
      rescue OS::Error
        raise "invalid elevation data"
      end

      return tif_path
    end
  end
end

module NSWTopo
  module Relief
    include Raster, MaskRender, DEM, Log
    CREATE = %w[method azimuth factor smooth contours]
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
      dem_path = temp_dir / "dem.tif"

      case
      when @path
        get_dem temp_dir, dem_path

      when @contours
        bounds = @map.bounds(margin: margin)
        txe, tye, spat = bounds[0], bounds[1].reverse, bounds.transpose.flatten
        outsize = (bounds.transpose.diff / @resolution).map(&:ceil)

        collection = @contours.map do |url_or_path, attribute_or_hash|
          raise "no elevation attribute specified for #{url_or_path}" unless attribute_or_hash
          options   = Hash === attribute_or_hash ? attribute_or_hash.transform_keys(&:to_sym).slice(:where, :layer) : {}
          attribute = Hash === attribute_or_hash ? attribute_or_hash["attribute"] : attribute_or_hash
          case url_or_path
          when ArcGIS::Service
            layer = ArcGIS::Service.new(url_or_path).layer(**options, geometry: @map.bounding_box(margin))
            layer.features do |count, total|
              log_update "%s: retrieved %i of %i contours" % [@name, count, total]
            end
          when Shapefile::Source
            Shapefile::Source.new(url_or_path).layer(**options, geometry: @map.bounding_box(margin), projection: @map.projection).features
          else
            raise "unrecognised elevation data source: #{url_or_path}"
          end.each do |feature|
            feature.properties.replace "elevation" => feature.fetch(attribute, attribute).to_f
          end.reproject_to(@map.projection)
        end.inject(&:merge)

        log_update "%s: calculating DEM" % @name
        OS.gdal_grid "-a", "linear:radius=0:nodata=-9999", "-zfield", "elevation", "-ot", "Float32", "-txe", *txe, "-tye", *tye, "-spat", *spat, "-outsize", *outsize, "/vsistdin/", dem_path do |stdin|
          stdin.puts collection.to_json
        end

      else
        raise "no elevation data specified for relief layer #{@name}"
      end

      raw_path = temp_dir / "relief.raw.tif"
      tif_path = temp_dir / "relief.tif"

      begin
        log_update "%s: generating shaded relief" % @name
        OS.gdaldem *%W[hillshade -q -compute_edges -s 1 -z #{@factor} -az #{@azimuth} -#{@method}], dem_path, raw_path
        OS.gdalwarp "-t_srs", @map.projection, raw_path, tif_path
      rescue OS::Error
        raise "invalid elevation data"
      end

      return @resolution, tif_path
    end
  end
end

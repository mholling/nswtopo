module NSWTopo
  class ReliefSource
    include RasterRenderer
    PARAMS = %q[
      embed: true
      altitude: 45
      azimuth: 315
      exaggeration: 2.5
      lightsources: 3
      resolution: 30.0
      opacity: 0.3
      highlights: 20
      median: 3
      bilateral: 4
      sigma: 100
    ]
    
    def initialize(name, params)
      super name, YAML.load(PARAMS).merge(params)
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      dem_path = temp_dir + "dem.tif"
      altitude, azimuth, exaggeration, highlights, lightsources, sigma = params.values_at *%w[altitude azimuth exaggeration highlights lightsources sigma]
      bounds = map.bounds.map do |lower, upper|
        [ lower - 3 * sigma, upper + 3 * sigma ]
      end
      
      case
      when params["path"]
        src_path = temp_dir + "dem.txt"
        vrt_path = temp_dir + "dem.vrt"
        
        paths = [ *params["path"] ].map do |path|
          Pathname.glob path
        end.inject([], &:+).map(&:expand_path).tap do |paths|
          raise BadLayerError.new("no dem data files at specified path") if paths.empty?
        end
        src_path.write paths.join(?\n)
        
        %x[gdalbuildvrt -input_file_list "#{src_path}" "#{vrt_path}"]
        %x[gdalwarp -t_srs "#{map.projection}" -te #{bounds.flatten.values_at(0,2,1,3).join(?\s)} -tr #{resolution} #{resolution} -r bilinear "#{vrt_path}" "#{dem_path}"]
      when params["contours"]
        attribute = params["attribute"]
        gdal_version = %x[gdalinfo --version][/\d+(\.\d+(\.\d+)?)?/].split(?.).map(&:to_i)
        raise BadLayerError.new "no elevation attibute specified" unless attribute
        raise BadLayerError.new "GDAL version 2.1 or greater required for shaded relief" if ([ 2, 1 ] <=> gdal_version) == 1
        
        shp_path = temp_dir + "dem.contours"
        spat = bounds.flatten.values_at(0,2,1,3).join ?\s
        outsize = bounds.map do |bound|
          (bound[1] - bound[0]) / resolution
        end.map(&:ceil).join(?\s)
        txe, tye = bounds[0].join(?\s), bounds[1].reverse.join(?\s)
        
        %w[contours coastline].inject(nil) do |append, layer|
          next append unless dataset = params[layer]
          case dataset
          when /^(https?:\/\/.*)\/\d+\/query$/
            srs, max_record_count = ArcGIS.get_json(URI.parse "#{$1}?f=json").values_at "spatialReference", "maxRecordCount"
            wkt, wkid = srs["wkt"], srs["latestWkid"] || srs["wkid"]
            service_projection = Projection.new wkt ? "ESRI::#{wkt}".gsub(?", '\"') : "epsg:#{wkid == 102100 ? 3857 : wkid}"
            geometry = map.projection.transform_bounds_to(service_projection, bounds).flatten.values_at(0,2,1,3).join(?,)
            next unless object_ids = ArcGIS.get_json(URI.parse "#{dataset}?f=json&geometryType=esriGeometryEnvelope&geometry=#{geometry}&returnIdsOnly=true")["objectIds"]
            features = object_ids.each_slice([ *max_record_count, 500 ].min).map do |object_ids|
              ArcGIS.get_json(URI.parse "#{dataset}?f=json&outFields=*&objectIds=#{object_ids.join ?,}")
            end.inject do |results, page|
              results["features"] += page["features"]
              results
            end
            IO.popen %Q[ogr2ogr -s_srs "#{service_projection}" -t_srs "#{map.projection}" -nln #{layer} "#{shp_path}" /vsistdin/ #{DISCARD_STDERR}], "w+" do |pipe|
              pipe.write features.to_json
            end
          else
            %x[ogr2ogr -spat #{spat} -spat_srs "#{map.projection}" -t_srs "#{map.projection}" -nln #{layer} "#{shp_path}" "#{dataset}" #{DISCARD_STDERR}]
          end
          sql = case layer
          when "contours"  then "SELECT      #{attribute} FROM #{layer}"
          when "coastline" then "SELECT 0 AS #{attribute} FROM #{layer}"
          end
          %x[ogr2ogr -update #{append} -nln combined -sql "#{sql}" "#{shp_path}" "#{shp_path}"]
          "-append"
        end
        %x[gdal_grid -a linear:radius=0:nodata=-9999 -zfield #{attribute} -l combined -ot Float32 -txe #{txe} -tye #{tye} -spat #{spat} -a_srs "#{map.projection}" -outsize #{outsize} "#{shp_path}" "#{dem_path}"]
      else
        raise BadLayerError.new "online elevation data unavailable, please provide contour data or DEM path"
      end
      
      reliefs = -90.step(90, 90.0 / lightsources).select.with_index do |offset, index|
        index.odd?
      end.map do |offset|
        (azimuth + offset) % 360
      end.map do |azimuth|
        relief_path = temp_dir + "relief.#{azimuth}.bil"
        %x[gdaldem hillshade -of EHdr -compute_edges -s 1 -alt #{altitude} -z #{exaggeration} -az #{azimuth} "#{dem_path}" "#{relief_path}" #{DISCARD_STDERR}]
        raise BadLayerError.new("invalid elevation data") unless $?.success?
        [ azimuth, ESRIHdr.new(relief_path, 0) ]
      end.to_h
      
      relief_path = temp_dir + "relief.combined.bil"
      if reliefs.one?
        reliefs.values.first.write relief_path
      else
        blur_path = temp_dir + "dem.blurred.bil"
        nodata = JSON.parse(%x[gdalinfo -json "#{dem_path}"])["bands"][0]["noDataValue"]
        %x[gdal_translate -of EHdr "#{dem_path}" "#{blur_path}" #{DISCARD_STDERR}]
        dem = ESRIHdr.new blur_path, nodata
        
        # TODO: should sigma be in pixels instead of metres?
        (sigma.to_f / resolution).ceil.times.inject(dem.rows) do |rows|
          2.times.inject(rows) do |rows|
            rows.map do |row|
              row.map do |value|
                value && value.nan? ? nil : value
              end.each_cons(3).map do |window|
                window[1] && window.compact.inject(&:+) / window.compact.length
              end.push(nil).unshift(nil)
            end.transpose
          end
        end.flatten.tap do |blurred|
          ESRIHdr.new(dem, blurred).write blur_path
        end
        
        aspect_path = temp_dir + "aspect.bil"
        %x[gdaldem aspect -zero_for_flat -of EHdr "#{blur_path}" "#{aspect_path}"]
        aspect = ESRIHdr.new aspect_path, 0.0
        
        reliefs.map do |azimuth, relief|
          [ relief.values, aspect.values ].transpose.map do |relief, aspect|
            relief ? aspect ? 2 * relief * Math::sin((aspect - azimuth) * Math::PI / 180)**2 : relief : 0
          end
        end.transpose.map do |values|
          values.inject(&:+) / lightsources
        end.map do |value|
          [ 255, value.ceil ].min
        end.tap do |values|
          ESRIHdr.new(reliefs.values.first, values).write relief_path
        end
      end
      
      tif_path = temp_dir + "relief.combined.tif"
      tfw_path = temp_dir + "relief.combined.tfw"
      map.write_world_file tfw_path, resolution
      density = 0.01 * map.scale / resolution
      %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type GrayscaleMatte -depth 8 "#{tif_path}"]
      %x[gdalwarp -s_srs "#{map.projection}" -t_srs "#{map.projection}" -srcnodata 0 -r bilinear -dstalpha "#{relief_path}" "#{tif_path}"]
      
      filters = []
      if args = params["median"]
        pixels = (2 * args + 1).to_i
        filters << "-channel RGBA -statistic median #{pixels}x#{pixels}"
      end
      if args = params["bilateral"]
        threshold, sigma = *args, (60.0 / resolution).round
        filters << "-channel RGB -selective-blur 0x#{sigma}+#{threshold}%"
      end
      %x[mogrify -quiet -virtual-pixel edge #{filters.join ?\s} "#{tif_path}"] if filters.any?
      
      threshold = Math::sin(altitude * Math::PI / 180)
      shade = %Q["#{tif_path}" -colorspace Gray -fill white -opaque none -level #{   90*threshold}%,0%                            -alpha Copy -fill black  +opaque black ]
      sun   = %Q["#{tif_path}" -colorspace Gray -fill black -opaque none -level #{10+90*threshold}%,100% +level 0%,#{highlights}% -alpha Copy -fill yellow +opaque yellow]
      
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert -quiet #{OP} #{shade} #{CP} #{OP} #{sun} #{CP} -composite -define png:color-type=6 "#{raster_path}"]
      end
    end
  end
end

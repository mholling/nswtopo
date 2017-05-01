module NSWTopo
  class ReliefSource
    include RasterRenderer
    
    # TODO: do we need to densify the contour lines?
    # TODO: reduce sigma for better performance?
    # TODO: try gmt triangulation in addition to gdal_grid
    
    PARAMS = %q[
      altitude: 45
      azimuth: 315
      exaggeration: 2.5
      lightsources: 3
      resolution: 30.0
      opacity: 0.3
      highlights: 20
      median: 30.0
      bilateral: 5
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
        
        dem_projection = Projection.new vrt_path
        dem_bounds = map.projection.transform_bounds_to dem_projection, bounds
        scale = bounds.zip(dem_bounds).last.map do |bound|
          bound.inject(&:-)
        end.inject(&:/)
        
        ulx, lrx, lry, uly = dem_bounds.flatten
        %x[gdal_translate -q -projwin #{ulx} #{uly} #{lrx} #{lry} "#{vrt_path}" "#{dem_path}"]
      when params["contours"]
        attribute = params["attribute"]
        gdal_version = %x[gdalinfo --version][/\d+(\.\d+(\.\d+)?)?/].split(?.).map(&:to_i)
        raise BadLayerError.new "no elevation attibute specified" unless attribute
        raise BadLayerError.new "GDAL version 2.1 or greater required for shaded relief" if ([ 2, 1 ] <=> gdal_version) == 1
        
        shp_path = temp_dir + "dem-contours"
        spat = bounds.flatten.values_at(0,2,1,3).join ?\s
        outsize = bounds.map do |bound|
          (bound[1] - bound[0]) / resolution
        end.map(&:ceil).join(?\s)
        txe, tye = bounds[0].join(?\s), bounds[1].reverse.join(?\s)
        
        ogr2ogr = %Q[ogr2ogr -spat #{spat} -spat_srs "#{map.projection}" -t_srs "#{map.projection}"]
        %w[contours coastline].map do |layer|
          next unless dataset = params[layer]
          case dataset
          when /^(https?:\/\/.*)\/\d+\/query$/
            service = HTTP.get(URI.parse "#{$1}?f=json") do |response|
              JSON.parse response.body
            end
            raise BadLayerError.new service["error"]["message"] if service["error"]
            wkt  = service["spatialReference"]["wkt"]
            wkid = service["spatialReference"]["latestWkid"] || service["spatialReference"]["wkid"]
            service_projection = Projection.new wkt ? "ESRI::#{wkt}".gsub(?", '\"') : "epsg:#{wkid == 102100 ? 3857 : wkid}"
            geometry = map.projection.transform_bounds_to(service_projection, bounds).flatten.values_at(0,2,1,3).join(?,)
            url = "#{dataset}?where=objectid+%3D+objectid&outfields=*&f=json&geometryType=esriGeometryEnvelope&geometry=#{geometry}"
            %x[#{ogr2ogr} -nln #{layer}_temp -s_srs "#{service_projection}" "#{shp_path}" "#{url}" #{DISCARD_STDERR}]
          else
            %x[#{ogr2ogr} -nln #{layer}_temp "#{shp_path}" "#{dataset}" #{DISCARD_STDERR}]
          end
          case layer
          when "contours"  then %x[ogr2ogr -nln #{layer} -sql "SELECT      #{attribute} FROM #{layer}_temp" "#{shp_path}" "#{shp_path}"]
          when "coastline" then %x[ogr2ogr -nln #{layer} -sql "SELECT 0 AS #{attribute} FROM #{layer}_temp" "#{shp_path}" "#{shp_path}"]
          end
          %Q[-l #{layer} -zfield "#{attribute}"]
        end.compact.join(?\s).tap do |layers|
          %x[gdal_grid -a linear:radius=0:nodata=-9999 #{layers} -ot Float32 -txe #{txe} -tye #{tye} -spat #{spat} -a_srs "#{map.projection}" -outsize #{outsize} "#{shp_path}" "#{dem_path}"]
        end
        dem_projection, scale = map.projection, 1
      else
        raise BadLayerError.new "online elevation data unavailable, please provide contour data or DEM path"
      end
      
      azimuths = -90.step(90, 90.0 / lightsources).select.with_index do |offset, index|
        index.odd?
      end.map do |offset|
        (azimuth + offset) % 360
      end
      
      relief_paths = azimuths.map do |azimuth|
        temp_dir + "relief.#{azimuth}.asc"
      end
      
      relief_paths.zip(azimuths).each do |relief_path, azimuth|
        %x[gdaldem hillshade -of AAIGrid -compute_edges -s #{scale} -alt #{altitude} -z #{exaggeration} -az #{azimuth} "#{dem_path}" "#{relief_path}" #{DISCARD_STDERR}]
        raise BadLayerError.new("invalid elevation data") unless $?.success?
      end
      
      if relief_paths.one?
        relief_path = relief_paths.first
      else
        dem_params = JSON.parse %x[gdalinfo -json "#{dem_path}"]
        resolutions = dem_params["geoTransform"].values_at(1, 5).map(&:abs)
        steps = (3 * sigma / scale / resolutions.min).ceil
        coefs = resolutions.map do |resolution|
          (1..steps).inject([ 0 ]) do |values, index|
            [ -index * resolution / sigma, *values, index * resolution / sigma ]
          end.map do |z|
            Math::exp(-0.5 * z * z)
          end
        end.inject(&:product).map do |x, y|
          x * y
        end
        sum = coefs.inject(&:+)
        coefs.map! { |coef| coef / sum }
        
        vrt_path = temp_dir + "dem-blurred.vrt"
        %x[gdalbuildvrt "#{vrt_path}" "#{dem_path}"]
        vrt = REXML::Document.new(vrt_path.read)
        vrt.elements.each("//ComplexSource|//SimpleSource") do |source|
          source.name = "KernelFilteredSource"
          kernel = source.add_element("Kernel")
          kernel.add_element("Size").text = 2 * steps + 1
          kernel.add_element("Coefs").text = coefs.join(?\s)
        end
        vrt_path.write vrt
        
        relief_path = temp_dir + "relief.combined.asc"
        aspect_path = temp_dir + "aspect.asc"
        %x[gdaldem aspect -of AAIGrid "#{vrt_path}" "#{aspect_path}" #{DISCARD_STDERR}]
        
        ncols, nrows = aspect_path.each_line.take(2).map { |line| line[/\d+/].to_i }
        header = aspect_path.each_line.count - nrows
        aspect, *reliefs = [ aspect_path, *relief_paths ].map(&:each_line).map do |lines|
          lines.drop(header).map(&:split).flatten.map(&:to_f)
        end
        
        reliefs.zip(azimuths).map do |relief, azimuth|
          relief.zip(aspect).map do |relief, aspect|
            relief * (aspect < 0 ? 1 : 2 * Math::sin((aspect - azimuth) * Math::PI / 180)**2)
          end
        end.transpose.map do |values|
          values.inject(&:+) / lightsources
        end.map do |value|
          [ 255, value.ceil ].min
        end.each_slice(ncols).map do |row|
          row.join ?\s
        end.tap do |lines|
          relief_path.write relief_paths.first.each_line.take(header).concat(lines).join(?\n)
        end
      end
      
      tif_path = temp_dir + "relief.combined.tif"
      tfw_path = temp_dir + "relief.combined.tfw"
      map.write_world_file tfw_path, resolution
      density = 0.01 * map.scale / resolution
      %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type GrayscaleMatte -depth 8 "#{tif_path}"]
      %x[gdalwarp -s_srs "#{dem_projection}" -t_srs "#{map.projection}" -srcnodata 0 -r bilinear -dstalpha "#{relief_path}" "#{tif_path}"]
      
      filters = []
      if args = params["median"]
        pixels = (args.to_f / resolution).round
        filters << "-channel RGBA -statistic median #{2 * pixels + 1}"
      end
      if args = params["bilateral"]
        threshold, sigma = *args
        sigma ||= (100.0 / resolution).round
        filters << "-channel RGB -selective-blur 0x#{sigma}+#{threshold}%"
      end
      %x[mogrify -quiet -virtual-pixel edge #{filters.join ?\s} "#{tif_path}"] if filters.any?
      
      flat_dem_path, flat_relief_path = temp_dir + "flat.dem.tif", temp_dir + "flat.relief.tif"
      %x[convert -size 10x10 canvas:black -type Grayscale -depth 8 "#{flat_dem_path}"]
      %x[gdaldem hillshade -compute_edges -alt #{altitude} "#{flat_dem_path}" "#{flat_relief_path}"]
      threshold = %x[convert -quiet "#{flat_relief_path}" -format "%[fx:mean]" info:].to_f.round(3)
      
      shade = %Q["#{tif_path}" -colorspace Gray -fill white -opaque none -level #{   90*threshold}%,0%                            -alpha Copy -fill black  +opaque black ]
      sun   = %Q["#{tif_path}" -colorspace Gray -fill black -opaque none -level #{10+90*threshold}%,100% +level 0%,#{highlights}% -alpha Copy -fill yellow +opaque yellow]
      
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert -quiet #{OP} #{shade} #{CP} #{OP} #{sun} #{CP} -composite -define png:color-type=6 "#{raster_path}"]
      end
    end
    
    def embed_image(temp_dir)
      raise BadLayerError.new("hillshade image not found at #{path}") unless path.exist?
      path
    end
  end
end

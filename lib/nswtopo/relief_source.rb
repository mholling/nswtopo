module NSWTopo
  class ReliefSource
    include RasterRenderer
    
    DEFAULT_SIGMA = 100
    PARAMS = %q[
      altitude: 45
      azimuth: 315
      exaggeration: 2
      sources: 1
      resolution: 30.0
      opacity: 0.3
      highlights: 20
      median: 30.0
      bilateral: 5
    ]
    
    def initialize(name, params)
      super name, YAML.load(PARAMS).merge(params).merge("ext" => "tif")
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      src_path = temp_dir + "dem.txt"
      vrt_path = temp_dir + "dem.vrt"
      dem_path = temp_dir + "dem.tif"
      
      sources, sigma = [ *params["sources"], DEFAULT_SIGMA ]
      
      bounds = map.bounds.map do |lower, upper|
        [ lower - 3 * sigma, upper + 3 * sigma ]
      end
      
      if params["path"]
        [ *params["path"] ].map do |path|
          Pathname.glob path
        end.inject([], &:+).map(&:expand_path).tap do |paths|
          raise BadLayerError.new("no dem data files at specified path") if paths.empty?
        end
      else
        base_uri = URI.parse "http://www.ga.gov.au/gisimg/rest/services/topography/dem_s_1s/ImageServer/"
        wgs84_bounds = map.projection.transform_bounds_to Projection.wgs84, bounds
        base_query = { "f" => "json", "geometry" => wgs84_bounds.map(&:sort).transpose.flatten.join(?,) }
        query = base_query.merge("returnIdsOnly" => true, "where" => "category = 1").to_query
        raster_ids = ArcGIS.get_json(base_uri + "query?#{query}").fetch("objectIds")
        query = base_query.merge("rasterIDs" => raster_ids.join(?,), "format" => "TIFF").to_query
        tile_paths = ArcGIS.get_json(base_uri + "download?#{query}").fetch("rasterFiles").map do |file|
          file["id"][/[^@]*/]
        end.select do |url|
          url[/\.tif$/]
        end.map do |url|
          [ URI.parse(URI.escape url), temp_dir + url[/[^\/]*$/] ]
        end.each do |uri, tile_path|
          HTTP.get(uri) do |response|
            tile_path.open("wb") { |file| file << response.body }
          end
        end.map(&:last)
      end.join(?\n).tap do |path_list|
        File.write src_path, path_list
      end
      %x[gdalbuildvrt -input_file_list "#{src_path}" "#{vrt_path}"]
      
      projection = Projection.new(vrt_path)
      dem_bounds = map.projection.transform_bounds_to projection, bounds
      
      ulx, lrx, lry, uly = dem_bounds.flatten
      %x[gdal_translate -q -projwin #{ulx} #{uly} #{lrx} #{lry} "#{vrt_path}" "#{dem_path}"]
      
      scale = bounds.zip(dem_bounds).last.map do |bound|
        bound.inject(&:-)
      end.inject(&:/)
      
      altitude, azimuth, exaggeration = params.values_at("altitude", "azimuth", "exaggeration")
      
      azimuths = -90.step(90, 90.0 / sources).select.with_index do |offset, index|
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
        steps = (3 * sigma / resolutions.min).ceil
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
            relief * (aspect < 0 ? 1 : 2 * Math::sin((aspect - azimuth) * Math::PI / 180)**2) / sources
          end
        end.inject do |sums, values|
          sums.zip(values).map { |sum, value| sum == 0 ? sum : sum + value }
        end.map do |value|
          [ 255, value.to_i ].min
        end.each_slice(ncols).map do |row|
          row.join ?\s
        end.tap do |lines|
          relief_path.write relief_paths.first.each_line.take(header).concat(lines).join(?\n)
        end
      end
      
      tif_path = temp_dir + "output.tif"
      tfw_path = temp_dir + "output.tfw"
      map.write_world_file tfw_path, resolution
      density = 0.01 * map.scale / resolution
      %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type GrayscaleMatte -depth 8 "#{tif_path}"]
      %x[gdalwarp -s_srs "#{projection}" -t_srs "#{map.projection}" -r bilinear -dstalpha "#{relief_path}" "#{tif_path}"]
      
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
      
      tif_path
    end
    
    def embed_image(temp_dir)
      raise BadLayerError.new("hillshade image not found at #{path}") unless path.exist?
      highlights = params["highlights"]
      shade = %Q["#{path}" -colorspace Gray -fill white -opaque none -level 0,65% -negate -alpha Copy -fill black +opaque black]
      sun = %Q["#{path}" -colorspace Gray -fill black -opaque none -level 80%,100% +level 0,#{highlights}% -alpha Copy -fill yellow +opaque yellow]
      temp_dir.join("overlay.png").tap do |overlay_path|
        %x[convert -quiet #{OP} #{shade} #{CP} #{OP} #{sun} #{CP} -composite -define png:color-type=6 "#{overlay_path}"]
      end
    end
  end
end

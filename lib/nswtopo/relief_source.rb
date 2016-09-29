module NSWTopo
  class ReliefSource < Source
    include RasterRenderer
    
    def initialize(name, params)
      super(name, params.merge("ext" => "tif"))
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      src_path = temp_dir + "dem.txt"
      vrt_path = temp_dir + "dem.vrt"
      dem_path = temp_dir + "dem.tif"
      
      bounds = map.bounds.map do |lower, upper|
        [ lower - 10.0 * resolution, upper + 10.0 * resolution ]
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
      
      dem_bounds = map.projection.transform_bounds_to Projection.new(vrt_path), bounds
      ulx, lrx, lry, uly = dem_bounds.flatten
      %x[gdal_translate -q -projwin #{ulx} #{uly} #{lrx} #{lry} "#{vrt_path}" "#{dem_path}"]
      
      scale = bounds.zip(dem_bounds).last.map do |bound|
        bound.inject(&:-)
      end.inject(&:/)
      
      temp_dir.join(path.basename).tap do |tif_path|
        relief_path = temp_dir + "#{name}-uncropped.tif"
        tfw_path = temp_dir + "#{name}.tfw"
        map.write_world_file tfw_path, resolution
        density = 0.01 * map.scale / resolution
        altitude, azimuth, exaggeration = params.values_at("altitude", "azimuth", "exaggeration")
        %x[gdaldem hillshade -compute_edges -s #{scale} -alt #{altitude} -z #{exaggeration} -az #{azimuth} "#{dem_path}" "#{relief_path}" -q]
        raise BadLayerError.new("invalid elevation data") unless $?.success?
        %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type GrayscaleMatte -depth 8 "#{tif_path}"]
        %x[gdalwarp -t_srs "#{map.projection}" -r bilinear -srcnodata 0 -dstalpha "#{relief_path}" "#{tif_path}"]
        filters = []
        (params["median"].to_f / resolution).round.tap do |pixels|
          filters << "-statistic median #{2 * pixels + 1}" if pixels > 0
        end
        params["bilateral"].to_f.round.tap do |threshold|
          sigma = (500.0 / resolution).round
          filters << "-selective-blur 0x#{sigma}+#{threshold}%" if threshold > 0
        end
        %x[mogrify -channel RGBA -quiet -virtual-pixel edge #{filters.join ?\s} "#{tif_path}"] if filters.any?
      end
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

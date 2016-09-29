module NSWTopo
  class ArcGISRaster
    include RasterRenderer
    UNDERSCORES = /[\s\(\)]/
    attr_reader :service, :headers
    
    def initialize(*args)
      super(*args)
      params["tile_sizes"] ||= [ 2048, 2048 ]
      params["url"] ||= (params["https"] ? URI::HTTPS : URI::HTTP).build(:host => params["host"]).to_s
      service_type = params["image"] ? "ImageServer" : "MapServer"
      params["url"] = [ params["url"], params["instance"] || "arcgis", "rest", "services", *params["folder"], params["service"], service_type ].join(?/)
    end
    
    def get_tile(bounds, sizes, options)
      srs = { "wkt" => options["wkt"] }.to_json
      query = {
        "bbox" => bounds.transpose.flatten.join(?,),
        "bboxSR" => srs,
        "imageSR" => srs,
        "size" => sizes.join(?,),
        "f" => "image"
      }
      if params["image"]
        query["format"] = "png24",
        query["interpolation"] = params["interpolation"] || "RSP_BilinearInterpolation"
      else
        %w[layers layerDefs dpi format dynamicLayers].each do |key|
          query[key] = options[key] if options[key]
        end
        query["transparent"] = true
      end
      
      url = params["url"]
      export = params["image"] ? "exportImage" : "export"
      uri = URI.parse "#{url}/#{export}?#{query.to_query}"
      
      HTTP.get(uri, headers) do |response|
        block_given? ? yield(response.body) : response.body
      end
    end
    
    def tiles(map, resolution, margin = 0)
      cropped_tile_sizes = params["tile_sizes"].map { |tile_size| tile_size - margin }
      dimensions = map.bounds.map { |bound| ((bound.max - bound.min) / resolution).ceil }
      origins = [ map.bounds.first.min, map.bounds.last.max ]
      
      cropped_size_lists = [ dimensions, cropped_tile_sizes ].transpose.map do |dimension, cropped_tile_size|
        [ cropped_tile_size ] * ((dimension - 1) / cropped_tile_size) << 1 + (dimension - 1) % cropped_tile_size
      end
      
      bound_lists = [ cropped_size_lists, origins, [ :+, :- ] ].transpose.map do |cropped_sizes, origin, increment|
        boundaries = cropped_sizes.inject([ 0 ]) { |memo, size| memo << size + memo.last }
        [ 0..-2, 1..-1 ].map.with_index do |range, index|
          boundaries[range].map { |offset| origin.send increment, (offset + index * margin) * resolution }
        end.transpose.map(&:sort)
      end
      
      size_lists = cropped_size_lists.map do |cropped_sizes|
        cropped_sizes.map { |size| size + margin }
      end
      
      offset_lists = cropped_size_lists.map do |cropped_sizes|
        cropped_sizes[0..-2].inject([0]) { |memo, size| memo << memo.last + size }
      end
      
      [ bound_lists, size_lists, offset_lists ].map do |axes|
        axes.inject(:product)
      end.transpose.select do |bounds, sizes, offsets|
        map.overlaps? bounds
      end
    end
    
    def get_service
      if params["cookie"]
        cookie = HTTP.head(URI.parse params["cookie"]) { |response| response["Set-Cookie"] }
        @headers = { "Cookie" => cookie }
      end
      uri = URI.parse params["url"] + "?f=json"
      @service = ArcGIS.get_json uri, headers
      service["layers"].each { |layer| layer["name"] = layer["name"].gsub(UNDERSCORES, ?_) } if service["layers"]
      service["mapName"] = service["mapName"].gsub(UNDERSCORES, ?_) if service["mapName"]
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      get_service
      scale = params["scale"] || map.scale
      options = { "dpi" => scale * 0.0254 / resolution, "wkt" => map.projection.wkt_esri, "format" => "png32" }
      
      tile_set = tiles(map, resolution)
      dataset = tile_set.map.with_index do |(tile_bounds, tile_sizes, tile_offsets), index|
        $stdout << "\r  (#{index} of #{tile_set.length} tiles)"
        tile_path = temp_dir + "tile.#{index}.png"
        tile_path.open("wb") do |file|
          file << get_tile(tile_bounds, tile_sizes, options)
        end
        [ tile_bounds, tile_sizes, tile_offsets, tile_path ]
      end
      puts
      
      temp_dir.join(path.basename).tap do |raster_path|
        density = 0.01 * map.scale / resolution
        alpha = params["background"] ? %Q[-background "#{params['background']}" -alpha Remove] : nil
        if map.rotation.zero?
          sequence = dataset.map do |_, tile_sizes, tile_offsets, tile_path|
            %Q[#{OP} "#{tile_path}" +repage -repage +#{tile_offsets[0]}+#{tile_offsets[1]} #{CP}]
          end.join ?\s
          resize = (params["resolution"] || params["scale"]) ? "-resize #{dimensions.join ?x}!" : "" # TODO: check?
          %x[convert #{sequence} -compose Copy -layers mosaic -units PixelsPerCentimeter -density #{density} #{resize} #{alpha} "#{raster_path}"]
        else
          src_path = temp_dir + "#{name}.txt"
          vrt_path = temp_dir + "#{name}.vrt"
          tif_path = temp_dir + "#{name}.tif"
          tfw_path = temp_dir + "#{name}.tfw"
          dataset.each do |tile_bounds, _, _, tile_path|
            topleft = [ tile_bounds.first.first, tile_bounds.last.last ]
            WorldFile.write topleft, resolution, 0, Pathname.new("#{tile_path}w")
          end.map(&:last).join(?\n).tap do |path_list|
            File.write src_path, path_list
          end
          %x[gdalbuildvrt -input_file_list "#{src_path}" "#{vrt_path}"]
          %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type TrueColorMatte -depth 8 "#{tif_path}"]
          map.write_world_file tfw_path, resolution
          %x[gdalwarp -s_srs "#{map.projection}" -t_srs "#{map.projection}" -dstalpha -r cubic "#{vrt_path}" "#{tif_path}"]
          %x[convert "#{tif_path}" -quiet #{alpha} "#{raster_path}"]
        end
      end
    end
  end
end

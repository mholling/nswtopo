module NSWTopo
  module RasterRenderer
    def initialize(*args)
      super(*args)
      ext = params["ext"] || "png"
      @path = Pathname.pwd + "#{name}.#{ext}"
    end
    
    def resolution_for(map)
      params["resolution"] || map.scale / 12500.0
    end
    
    def create(map)
      resolution = resolution_for map
      dimensions = map.extents.map { |extent| (extent / resolution).ceil }
      pixels = dimensions.inject(:*) > 500000 ? " (%.1fMpx)" % (0.000001 * dimensions.inject(:*)) : nil
      puts "Creating: %s, %ix%i%s @ %.1f m/px" % [ name, *dimensions, pixels, resolution]
      Dir.mktmppath do |temp_dir|
        FileUtils.cp get_raster(map, dimensions, resolution, temp_dir), path
      end
    end
    
    def render_svg(xml, map)
      resolution = resolution_for map
      transform = "scale(#{1000.0 * resolution / map.scale})"
      opacity = params["opacity"] || 1
      dimensions = map.extents.map { |extent| (extent / resolution).ceil }
      
      href = if respond_to?(:embed_image) && params["embed"] != false
        Dir.mktmppath do |temp_dir|
          raster_path = embed_image(temp_dir)
          base64 = Base64.encode64 raster_path.read(:mode => "rb")
          mimetype = %x[identify -quiet -verbose "#{raster_path}"][/image\/\w+/] || "image/png"
          "data:#{mimetype};base64,#{base64}"
        end
      else
        raise BadLayerError.new("#{name} raster image not found at #{path}") unless path.exist?
        path.basename
      end
      
      if layer = yield
        if params["masks"]
          defs = xml.elements["//svg/defs"]
          filter_id, mask_id = "#{name}#{SEGMENT}filter", "#{name}#{SEGMENT}mask"
          defs.elements.each("[@id='#{filter_id}' or @id='#{mask_id}']", &:remove)
          defs.add_element("filter", "id" => filter_id) do |filter|
            filter.add_element "feColorMatrix", "type" => "matrix", "in" => "SourceGraphic", "values" => "0 0 0 0 1   0 0 0 0 1   0 0 0 0 1   0 0 0 -1 1"
          end
          defs.add_element("mask", "id" => mask_id) do |mask|
            mask.add_element("g", "filter" => "url(##{filter_id})") do |g|
              g.add_element "rect", "width" => "100%", "height" => "100%", "fill" => "none", "stroke" => "none"
              [ *params["masks"] ].each do |id|
                g.add_element "use", "xlink:href" => "##{id}"
              end
            end
          end
          layer.add_element("g", "mask" => "url(##{mask_id})")
        else
          layer
        end.add_element("image", "transform" => transform, "width" => dimensions[0], "height" => dimensions[1], "image-rendering" => "optimizeQuality", "xlink:href" => href)
      end
    end
  end
end

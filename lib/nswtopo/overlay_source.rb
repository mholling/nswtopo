module NSWTopo
  class OverlaySource < Source
    include VectorRenderer
    include NoCreate
    
    def initialize(*args)
      super(*args)
      @path = Pathname.new(params["path"]).expand_path
    end
    
    def draw(map, &block)
      gps = GPS.new(path)
      [ [ :tracks, { "fill" => "none" }, nil ],
        [ :areas, { "fill-rule" => "nonzero" }, ?Z ]
      ].each do |feature, attributes, close|
        gps.send(feature).map do |list, name|
          points = map.coords_to_mm map.reproject_from_wgs84(list)
          d = points.to_path_data MM_DECIMAL_DIGITS, *close
          REXML::Element.new("g").tap do |g|
            g.add_attributes("class" => name.to_category)
            g.add_element "path", attributes.merge("d" => d)
          end
        end.each(&block)
      end
      gps.waypoints.group_by do |coords, name|
        name.to_category
      end.map do |category, coords_names|
        coords = map.reproject_from_wgs84(coords_names.transpose.first)
        REXML::Element.new("g").tap do |group|
          group.add_attributes("class" => category)
          map.coords_to_mm(coords).round(MM_DECIMAL_DIGITS).each do |x, y|
            transform = "translate(#{x} #{y}) rotate(#{-map.rotation})"
            group.add_element "use", "transform" => transform
          end
        end
      end.each(&block)
    rescue BadGpxKmlFile => e
      raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
    end
  end
end

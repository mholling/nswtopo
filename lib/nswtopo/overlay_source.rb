module NSWTopo
  class OverlaySource < Source
    include VectorRenderer
    include NoCreate
    
    def initialize(*args)
      super(*args)
      @path = Pathname.new(params["path"]).expand_path
    end
    
    def draw(map)
      gps = GPS.new(path)
      group = yield
      return unless group
      [ [ :tracks, { "fill" => "none" }, nil ],
        [ :areas, { "fill-rule" => "nonzero" }, ?Z ]
      ].each do |feature, attributes, close|
        gps.send(feature).each do |list, name|
          points = map.coords_to_mm map.reproject_from_wgs84(list)
          d = points.to_path_data MM_DECIMAL_DIGITS, *close
          group.add_element "g", "class" => name.to_category do |group|
            group.add_element "path", attributes.merge("d" => d)
          end
        end
      end
      gps.waypoints.group_by do |coords, name|
        name.to_category
      end.each do |category, coords_names|
        coords = map.reproject_from_wgs84(coords_names.transpose.first)
        group.add_element("g", "class" => category) do |category_group|
          map.coords_to_mm(coords).round(MM_DECIMAL_DIGITS).each do |x, y|
            transform = "translate(#{x} #{y}) rotate(#{-map.rotation})"
            category_group.add_element "use", "transform" => transform
          end
        end
      end
    rescue BadGpxKmlFile => e
      raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
    end
  end
end

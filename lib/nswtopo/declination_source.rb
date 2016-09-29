module NSWTopo
  class DeclinationSource < Source
    include VectorRenderer
    
    def draw(map, &block)
      arrows = params["arrows"]
      bl, br, tr, tl = map.coord_corners
      width, height = map.extents
      margin = height * Math::tan((map.rotation + map.declination) * Math::PI / 180.0)
      spacing = params["spacing"] / Math::cos((map.rotation + map.declination) * Math::PI / 180.0)
      [ [ bl, br ], [ tl, tr ] ].map.with_index do |edge, index|
        [ [ 0, 0 - margin ].min, [ width, width - margin ].max ].map do |extension|
          edge.along (extension + margin * index) / width
        end
      end.map do |edge|
        (edge.distance / spacing).ceil.times.map do |n|
          edge.along(n * spacing / edge.distance)
        end
      end.transpose.map do |line|
        map.coords_to_mm line
      end.map.with_index do |points, index|
        step = arrows || points.distance
        start = index.even? ? 0.25 : 0.75
        (points.distance / step - start).ceil.times.map do |n|
          points.along (start + n) * step / points.distance
        end.unshift(points.first).push(points.last)
      end.tap do |lines|
        lines.clip_lines! map.mm_corners
      end.map do |points|
        points.to_path_data MM_DECIMAL_DIGITS
      end.map do |d|
        REXML::Element.new("path").tap do |path|
          path.add_attributes("d" => d, "fill" => "none", "marker-mid" => arrows ? "url(##{name}#{SEGMENT}marker)" : "none")
        end
      end.each(&block)
      REXML::Element.new("marker").tap do |marker|
        marker.add_attributes("id" => "#{name}#{SEGMENT}marker", "markerWidth" => 20, "markerHeight" => 8, "viewBox" => "-20 -4 20 8", "orient" => "auto")
        marker.add_element("path", "d" => "M 0 0 L -20 -4 L -13 0 L -20 4 Z", "stroke" => "none", "fill" => params["stroke"] || "black")
        yield marker, nil, true
      end if arrows
    rescue ServerError => e
      raise BadLayerError.new(e.message)
    end
  end
end

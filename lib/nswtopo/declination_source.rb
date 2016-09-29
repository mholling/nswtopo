module NSWTopo
  class DeclinationSource < Source
    include VectorRenderer
    
    def draw(map)
      arrows = params["arrows"]
      bl, br, tr, tl = map.coord_corners
      width, height = map.extents
      margin = height * Math::tan((map.rotation + map.declination) * Math::PI / 180.0)
      spacing = params["spacing"] / Math::cos((map.rotation + map.declination) * Math::PI / 180.0)
      group = yield
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
      end.each do |d|
        group.add_element("path", "d" => d, "fill" => "none", "marker-mid" => arrows ? "url(##{name}#{SEGMENT}marker)" : "none")
      end.tap do
        group.elements["//svg/defs"].add_element("marker", "id" => "#{name}#{SEGMENT}marker", "markerWidth" => 20, "markerHeight" => 8, "viewBox" => "-20 -4 20 8", "orient" => "auto") do |marker|
          marker.add_element("path", "d" => "M 0 0 L -20 -4 L -13 0 L -20 4 Z", "stroke" => "none", "fill" => params["stroke"] || "black")
        end if arrows
      end if group
    rescue ServerError => e
      raise BadLayerError.new(e.message)
    end
  end
end

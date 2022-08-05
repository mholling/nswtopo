module NSWTopo
  module GeoJSON
    class MultiPoint
      def clip(hull)
        [hull, hull.perps].transpose.inject(@coordinates) do |result, (vertex, perp)|
          result.select { |point| point.minus(vertex).dot(perp) >= 0 }
        end.then do |points|
          points.none? ? nil : points.one? ? Point.new(*points, @properties) : MultiPoint.new(points, @properties)
        end
      end
    end
  end
end

module NSWTopo
  module GeoJSON
    class MultiPoint
      def clip(hull)
        points = [hull, hull.perps].transpose.inject(@coordinates) do |result, (vertex, perp)|
          result.select { |point| point.minus(vertex).dot(perp) >= 0 }
        end
        points.none? ? nil : points.one? ? Point.new(*points, @properties) : MultiPoint.new(points, @properties)
      end
    end
  end
end

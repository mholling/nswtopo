module NSWTopo
  module GeoJSON
    class MultiLineString
      def clip(hull)
        lines = [hull, hull.perps].transpose.inject(@coordinates) do |result, (vertex, perp)|
          result.inject([]) do |clipped, points|
            clipped + [*points, points.last].segments.inject([[]]) do |lines, segment|
              inside = segment.map { |point| point.minus(vertex).dot(perp) >= 0 }
              case
              when inside.all?
                lines.last << segment[0]
              when inside[0]
                lines.last << segment[0]
                lines.last << segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
              when inside[1]
                lines << []
                lines.last << segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
              end
              lines
            end
          end
        end.select(&:many?)
        lines.none? ? nil : lines.one? ? LineString.new(*lines, @properties) : MultiLineString.new(lines, @properties)
      end

      def length
        @coordinates.sum(&:path_length)
      end
    end
  end
end

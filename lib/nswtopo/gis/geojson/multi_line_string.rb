module NSWTopo
  module GeoJSON
    class MultiLineString
      include StraightSkeleton

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

      def offset(*margins, **options)
        linestrings = margins.inject Nodes.new(@coordinates) do |nodes, margin|
          nodes.progress limit: margin, **options.slice(:rounding_angle, :cutoff_angle)
        end.readout
        MultiLineString.new linestrings, @properties
      end

      def buffer(*margins, **options)
        MultiLineString.new(@coordinates + @coordinates.map(&:reverse), @properties).offset(*margins, **options)
      end

      def smooth(margin, **options)
        linestrings = Nodes.new(@coordinates).tap do |nodes|
          nodes.progress **options.slice(:rounding_angle).merge(limit: margin)
          nodes.progress **options.slice(:rounding_angle, :cutoff_angle).merge(limit: -2 * margin)
          nodes.progress **options.slice(:rounding_angle, :cutoff_angle).merge(limit: margin)
        end.readout
        MultiLineString.new linestrings, @properties
      end

      def samples(interval)
        points = @coordinates.map do |linestring|
          distance = linestring.path_length
          linestring.sample_at(interval, along: true).map do |point, along|
            [point, (2 * along - distance).abs - distance]
          end
        end.flatten(1).sort_by(&:last).map(&:first)
        MultiPoint.new points, @properties
      end
    end
  end
end

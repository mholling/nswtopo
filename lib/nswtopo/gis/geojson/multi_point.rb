module NSWTopo
  module GeoJSON
    class MultiPoint
      alias dissolve_points itself

      def rotate_by_degrees(angle)
        points = @coordinates.map { |point| point.rotate_by_degrees(angle) }
        MultiPoint.new points, @properties
      end

      def convex_hull
        start = self.min
        points, remaining = partition { |point| point == start }
        remaining.sort_by do |point|
          next (point - start).angle, (point - start).norm
        end.inject(points) do |points, v2|
          while points.length > 1 do
            v0, v1 = points.last(2)
            (v2 - v0).cross(v1 - v0) < 0 ? break : points.pop
          end
          points << v2
        end
      end

      def minimum_bbox_angle(*margins)
        ring = convex_hull
        return 0 if ring.one?
        indices = [%i[min_by max_by], %i[x y]].inject(:product).map do |min, coord|
          ring.map(&coord).each.with_index.send(min, &:first).last
        end
        calipers = [Vector[0, -1], Vector[1, 0], Vector[0, 1], Vector[-1, 0]]
        rotation = 0.0
        candidates = []

        while rotation < Math::PI / 2
          edges = indices.map do |index|
            ring[(index + 1) % ring.length] - ring[index]
          end
          angle, which = [edges, calipers].transpose.map do |edge, caliper|
            Math::acos caliper.proj(edge).clamp(-1, 1)
          end.map.with_index.min_by(&:first)

          calipers.map! { |caliper| caliper.rotate_by(angle) }
          rotation += angle

          break if rotation >= Math::PI / 2

          dimensions = [0, 1].map do |offset|
            (ring[indices[offset + 2]] - ring[indices[offset]]).proj(calipers[offset + 1])
          end

          if rotation < Math::PI / 4
            candidates << [dimensions, rotation]
          else
            candidates << [dimensions.reverse, rotation - Math::PI / 2]
          end

          indices[which] += 1
          indices[which] %= ring.length
        end

        candidates.min_by do |dimensions, rotation|
          dimensions.zip(margins).map do |dimension, margin|
            margin ? dimension + 2 * margin : dimension
          end.inject(:*)
        end.last
      end
    end
  end
end

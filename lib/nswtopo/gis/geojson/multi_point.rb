module NSWTopo
  module GeoJSON
    class MultiPoint
      alias dissolve_points itself

      def rotate_by_degrees!(angle)
        @coordinates.each { |point| point.rotate_by_degrees! angle }
      end

      def minimum_bbox_angle(*margins)
        ring = @coordinates.convex_hull
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

          calipers.each { |caliper| caliper.rotate_by!(angle) }
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

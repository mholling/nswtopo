module NSWTopo
  module GeoJSON
    class MultiPolygon
      def clip(hull)
        polys = @coordinates.inject([]) do |result, rings|
          lefthanded = rings.first.clockwise?
          interior, exterior = hull.zip(hull.perps).inject(rings) do |rings, (vertex, perp)|
            insides, neighbours, clipped = Hash[].compare_by_identity, Hash[].compare_by_identity, []
            rings.each do |points|
              points.map do |point|
                point.minus(vertex).dot(perp) >= 0
              end.segments.zip(points.segments).each do |inside, segment|
                insides[segment] = inside
                neighbours[segment] = [nil, nil]
              end.map(&:last).ring.each do |segment0, segment1|
                neighbours[segment1][0], neighbours[segment0][1] = segment0, segment1
              end
            end
            neighbours.select! do |segment, _|
              insides[segment].any?
            end
            insides.select do |segment, inside|
              inside.inject(&:^)
            end.each do |segment, inside|
              segment[inside[0] ? 1 : 0] = segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
            end.sort_by do |segment, inside|
              segment[inside[0] ? 1 : 0].minus(vertex).cross(perp) * (lefthanded ? -1 : 1)
            end.map(&:first).each_slice(2) do |segment0, segment1|
              segment = [segment0[1], segment1[0]]
              neighbours[segment0][1] = neighbours[segment1][0] = segment
              neighbours[segment] = [segment0, segment1]
            end
            while neighbours.any?
              segment, * = neighbours.first
              clipped << []
              while neighbours.include? segment
                clipped.last << segment[0]
                *, segment = neighbours.delete(segment)
              end
              clipped.last << clipped.last.first
            end
            clipped
          end.partition(&:clockwise?).rotate(lefthanded ? 1 : 0)
          next result << exterior + interior if exterior.one?
          exterior.inject(result) do |result, exterior_ring|
            within, interior = interior.partition do |interior_ring|
              interior_ring.first.within? exterior_ring
            end
            result << [exterior_ring, *within]
          end
        end
        polys.none? ? nil : polys.one? ? Polygon.new(*polys, @properties) : MultiPolygon.new(polys, @properties)
      end

      def area
        @coordinates.flatten(1).sum(&:signed_area)
      end
    end
  end
end

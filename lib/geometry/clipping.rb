module Clipping
  def clip_points(hull)
    [ hull, hull.perps ].transpose.inject(self) do |result, (vertex, perp)|
      result.select { |point| point.minus(vertex).dot(perp) >= 0 }
    end
  end
  
  def clip_points!(hull)
    replace clip_points(hull)
  end
  
  def clip_lines(hull)
    [ hull, hull.perps ].transpose.inject(self) do |result, (vertex, perp)|
      result.inject([]) do |clipped, points|
        clipped + [ *points, points.last ].segments.inject([[]]) do |lines, segment|
          inside = segment.map { |point| point.minus(vertex).dot(perp) >= 0 }
          case
          when inside.all?
            lines.last << segment[0]
          when inside[0]
            lines.last << segment[0]
            lines.last << segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
          when inside[1]
            lines << [ ]
            lines.last << segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
          end
          lines
        end
      end
    end.select(&:many?)
  end
  
  def clip_lines!(hull)
    replace clip_lines(hull)
  end
  
  def clip_polys(hull)
    handedness = first.hole? ? -1 : 1
    hull.zip(hull.perps).inject(self) do |polygons, (vertex, perp)|
      polygons.chunk do |points|
        points.signed_area * handedness >= 0
      end.map(&:last).each_slice(2).map do |polys, holes|
        insides, neighbours, result = Hash[].compare_by_identity, Hash[].compare_by_identity, []
        [ *polys, *holes ].each do |points|
          points.map do |point|
            point.minus(vertex).dot(perp) >= 0
          end.ring.zip(points.ring).each do |inside, segment|
            insides[segment] = inside
            neighbours[segment] = [ nil, nil ]
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
          segment[inside[0] ? 1 : 0].minus(vertex).cross(perp) * handedness
        end.map(&:first).each_slice(2) do |segment0, segment1|
          segment = [ segment0[1], segment1[0] ]
          neighbours[segment0][1] = neighbours[segment1][0] = segment
          neighbours[segment] = [ segment0, segment1 ]
        end
        while neighbours.any?
          segment, * = neighbours.first
          result << []
          while neighbours.include? segment
            result.last << segment[0]
            *, segment = neighbours.delete(segment)
          end
        end
        result.partition do |points|
          points.signed_area * handedness >= 0
        end.flatten(1)
      end.flatten(1)
    end
  end
  
  def clip_polys!(hull)
    replace clip_polys(hull)
  end
end

Array.send :include, Clipping

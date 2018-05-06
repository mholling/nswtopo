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
    [ hull, hull.perps ].transpose.inject(self) do |polygons, (vertex, perp)|
      polygons.inject([]) do |clipped, polygon|
        insides = polygon.map { |point| point.minus(vertex).dot(perp) >= 0 }
        case
        when insides.all? then clipped << polygon
        when insides.none?
        else
          outgoing = insides.ring.map.with_index.select { |inside, index| inside[0] && !inside[1] }.map(&:last)
           ingoing = insides.ring.map.with_index.select { |inside, index| !inside[0] && inside[1] }.map(&:last)
          pairs = [ outgoing, ingoing ].map do |indices|
            polygon.ring.map.with_index.to_a.values_at(*indices).map do |segment, index|
              [ segment.along(vertex.minus(segment[0]).dot(perp).to_f / segment.difference.dot(perp)), index ]
            end.sort_by do |intersection, index|
              [ vertex.minus(intersection).dot(perp.perp), index ]
            end
          end.transpose
          clipped << []
          while pairs.any?
            index ||= pairs[0][1][1]
            start ||= pairs[0][0][1]
            pair = pairs.min_by do |pair|
              intersections, indices = pair.transpose
              (indices[0] - index) % polygon.length
            end
            pairs.delete pair
            intersections, indices = pair.transpose
            while (indices[0] - index) % polygon.length > 0
              index += 1
              index %= polygon.length
              clipped.last << polygon[index]
            end
            clipped.last << intersections[0] << intersections[1]
            if index == start
              clipped << []
              index = start = nil
            else
              index = indices[1]
            end
          end
        end
        clipped.select(&:any?)
      end
    end
  end
  
  def clip_polys!(hull)
    replace clip_polys(hull)
  end
end

Array.send :include, Clipping

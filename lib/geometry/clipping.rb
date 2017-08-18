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
    lefthanded = first.hole?
    chunk(&:hole?).map(&:last).each_slice(2).map do |polys, holes|
      polys.zip.tap { |*, last| last.concat holes if holes }
    end.flatten(1).map do |rings|
      holes, polys = hull.zip(hull.perps).inject(rings) do |rings, (vertex, perp)|
        insides, neighbours, result = Hash[].compare_by_identity, Hash[].compare_by_identity, []
        rings.each do |points|
          points.map do |point|
            point.minus(vertex).dot(perp) >= 0
          end.segments.zip(points.segments).each do |inside, segment|
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
          segment[inside[0] ? 1 : 0].minus(vertex).cross(perp) * (lefthanded ? -1 : 1)
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
          result.last << result.last.first
        end
        result
      end.partition(&:hole?).rotate(lefthanded ? 1 : 0)
      next polys + holes if polys.one?
      polys.inject([]) do |memo, polygon|
        memo << polygon
        within, holes = holes.partition do |hole|
          hole.first.within? polygon
        end
        memo.concat within
      end
    end.flatten(1)
  end

  def clip_polys!(hull)
    replace clip_polys(hull)
  end
end

Array.send :include, Clipping

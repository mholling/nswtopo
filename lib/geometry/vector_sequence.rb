module VectorSequence
  def perps
    ring.map(&:difference).map(&:perp)
  end
  
  def signed_area
    0.5 * ring.map { |p1, p2| p1.cross p2 }.inject(&:+)
  end
  
  def centroid
    ring.map do |p1, p2|
      (p1.plus p2).times(p1.cross p2)
    end.inject(&:plus).times(1.0 / 6.0 / signed_area)
  end
  
  def convex?
    ring.map(&:difference).ring.all? do |directions|
      directions.inject(&:cross) >= 0
    end
  end
  
  def surrounds?(points)
    Enumerator.new do |yielder|
      points.each do |point|
        yielder << [ self, perps ].transpose.all? { |vertex, perp| point.minus(vertex).dot(perp) >= 0 }
      end
    end
  end
  
  def convex_hull
    start = min_by(&:reverse)
    hull, remaining = partition { |point| point == start }
    remaining.sort_by do |point|
      [ point.minus(start).angle, point.minus(start).norm ]
    end.inject(hull) do |memo, p3|
      while memo.many? do
        p1, p2 = memo.last(2)
        (p3.minus p1).cross(p2.minus p1) < 0 ? break : memo.pop
      end
      memo << p3
    end
  end
  
  def minimum_bounding_box
    polygon = convex_hull
    indices = [ [ :min_by, :max_by ], [ 0, 1 ] ].inject(:product).map do |min, axis|
      polygon.map.with_index.send(min) { |point, index| point[axis] }.last
    end
    calipers = [ [ 0, -1 ], [ 1, 0 ], [ 0, 1 ], [ -1, 0 ] ]
    rotation = 0.0
    candidates = []

    while rotation < Math::PI / 2
      edges = indices.map do |index|
        polygon[(index + 1) % polygon.length].minus polygon[index]
      end
      angle, which = [ edges, calipers ].transpose.map do |edge, caliper|
        Math::acos(edge.dot(caliper) / edge.norm)
      end.map.with_index.min_by { |angle, index| angle }
  
      calipers.each { |caliper| caliper.rotate_by!(angle) }
      rotation += angle
  
      break if rotation >= Math::PI / 2
  
      dimensions = [ 0, 1 ].map do |offset|
        polygon[indices[offset + 2]].minus(polygon[indices[offset]]).proj(calipers[offset + 1])
      end
  
      centre = polygon.values_at(*indices).map do |point|
        point.rotate_by(-rotation)
      end.partition.with_index do |point, index|
        index.even?
      end.map.with_index do |pair, index|
        0.5 * pair.map { |point| point[index] }.inject(:+)
      end.rotate_by(rotation)
  
      if rotation < Math::PI / 4
        candidates << [ centre, dimensions, rotation ]
      else
        candidates << [ centre, dimensions.reverse, rotation - Math::PI / 2 ]
      end
  
      indices[which] += 1
      indices[which] %= polygon.length
    end

    candidates.min_by { |centre, dimensions, rotation| dimensions.inject(:*) }
  end
  
  def path_length
    segments.map(&:difference).map(&:norm).inject(0, &:+)
  end
  
  def crop(length)
    start = 0.5 * (path_length - length)
    stop = start + length
    points, total = [], 0
    segments.each do |segment|
      distance = segment.distance
      case
      when total + distance <= start
      when total <= start
        points << segment.along((start - total) / distance)
        points << segment.along((stop  - total) / distance) if total + distance >= stop
      else
        points << segment[0]
        points << segment.along((stop  - total) / distance) if total + distance >= stop
      end
      total += distance
      break if total >= stop
    end
    points
  end
end

Array.send :include, VectorSequence

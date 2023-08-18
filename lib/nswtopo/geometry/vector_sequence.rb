module VectorSequence
  def signed_area
    0.5 * each_cons(2).sum { |v0, v1| v0.cross(v1) }
  end

  def clockwise?
    signed_area < 0
  end
  alias hole? clockwise?

  def anticlockwise?
    signed_area >= 0
  end

  def centroid
    each_cons(2).map do |v0, v1|
      (v0 + v1) * v0.cross(v1)
    end.inject(&:+) / (6 * signed_area)
  end

  def surrounds?(points)
    points.all? do |point|
      point.within? self
    end
  end

  def convex_hull
    start = min_by { |x, y| next y, x }
    hull, remaining = uniq.partition { |point| point == start }
    remaining.sort_by do |point|
      next (point - start).angle, (point - start).norm
    end.inject(hull) do |memo, v2|
      while memo.length > 1 do
        v0, v1 = memo.last(2)
        (v2 - v0).cross(v1 - v0) < 0 ? break : memo.pop
      end
      memo << v2
    end
  end
end

Array.send :include, VectorSequence

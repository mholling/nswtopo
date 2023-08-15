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

  def path_length
    each_cons(2).sum { |v0, v1| (v1 - v0).norm }
  end

  def trim(margin)
    start = [margin, 0].max
    stop = path_length - start
    return [] unless start < stop
    points, total = [], 0
    each_cons(2) do |v0, v1|
      distance = (v1 - v0).norm
      case
      when total + distance <= start
      when total <= start
        points << (v0 * (distance + total - start) + v1 * (start - total)) / distance
        points << (v0 * (distance + total - stop ) + v1 * (stop  - total)) / distance if total + distance >= stop
      else
        points << v0
        points << (v0 * (distance + total - stop ) + v1 * (stop  - total)) / distance if total + distance >= stop
      end
      total += distance
      break if total >= stop
    end
    points
  end

  def crop(length)
    trim(0.5 * (path_length - length))
  end

  def sample_at(interval, offset: nil)
    Enumerator.new do |yielder|
      alpha = (0.5 + Float(offset || 0) / interval) % 1.0
      each_cons(2).inject [alpha, 0] do |(alpha, along), (v0, v1)|
        angle = (v1 - v0).angle
        loop do
          distance = (v1 - v0).norm
          fraction = alpha * interval / distance
          break unless fraction < 1
          v0 = v1 * fraction + v0 * (1 - fraction)
          along += alpha * interval
          yielder << (block_given? ? yield(v0, along, angle) : v0)
          alpha = 1.0
        end
        distance = (v1 - v0).norm
        next alpha - distance / interval, along + distance
      end
    end.entries
  end

  def in_sections(count)
    each_cons(2).each_slice(count).map do |pairs|
      pairs.inject do |section, (p0, p1)|
        section << p1
      end
    end
  end

  def douglas_peucker(tolerance)
    chunks, simplified = [self], []
    while chunk = chunks.pop
      direction = (chunk.last - chunk.first).normalised
      deltas = chunk.map do |point|
        (point - chunk.first).cross(direction).abs
      end
      delta, index = deltas.each.with_index.max_by(&:first)
      if delta < tolerance
        simplified.prepend chunk.first
      else
        chunks << chunk[0..index] << chunk[index..-1]
      end
    end
    simplified << last
  end
end

Array.send :include, VectorSequence

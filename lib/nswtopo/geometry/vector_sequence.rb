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
      (v0.plus v1).times(v0.cross v1)
    end.inject(&:plus) / (6 * signed_area)
  end

  def surrounds?(points)
    points.all? do |point|
      point.within? self
    end
  end

  def convex_hull
    start = min_by(&:reverse)
    hull, remaining = uniq.partition { |point| point == start }
    remaining.sort_by do |point|
      [point.minus(start).angle, point.minus(start).norm]
    end.inject(hull) do |memo, v2|
      while memo.length > 1 do
        v0, v1 = memo.last(2)
        (v2.minus v0).cross(v1.minus v0) < 0 ? break : memo.pop
      end
      memo << v2
    end
  end

  def minimum_bounding_box(*margins)
    polygon = convex_hull
    return polygon[0], [0, 0], 0 if polygon.one?
    indices = [%i[min_by max_by], [0, 1]].inject(:product).map do |min, axis|
      polygon.map.with_index.send(min) { |point, index| point[axis] }.last
    end
    calipers = [[0, -1], [1, 0], [0, 1], [-1, 0]]
    rotation = 0.0
    candidates = []

    while rotation < Math::PI / 2
      edges = indices.map do |index|
        polygon[(index + 1) % polygon.length].minus polygon[index]
      end
      angle, which = [edges, calipers].transpose.map do |edge, caliper|
        Math::acos caliper.proj(edge).clamp(-1, 1)
      end.map.with_index.min_by { |angle, index| angle }

      calipers.each { |caliper| caliper.rotate_by!(angle) }
      rotation += angle

      break if rotation >= Math::PI / 2

      dimensions = [0, 1].map do |offset|
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
        candidates << [centre, dimensions, rotation]
      else
        candidates << [centre, dimensions.reverse, rotation - Math::PI / 2]
      end

      indices[which] += 1
      indices[which] %= polygon.length
    end

    candidates.min_by do |centre, dimensions, rotation|
      dimensions.zip(margins).map do |dimension, margin|
        margin ? dimension + 2 * margin : dimension
      end.inject(:*)
    end
  end

  def path_length
    each_cons(2).sum { |v0, v1| v1.minus(v0).norm }
  end

  def trim(margin)
    start = [margin, 0].max
    stop = path_length - start
    return [] unless start < stop
    points, total = [], 0
    each_cons(2) do |segment|
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

  def crop(length)
    trim(0.5 * (path_length - length))
  end

  def sample_at(interval, along: false, angle: false, offset: nil)
    Enumerator.new do |yielder|
      alpha = (0.5 + Float(offset || 0) / interval) % 1.0
      each_cons(2).inject [alpha, 0] do |(alpha, sum), segment|
        loop do
          fraction = alpha * interval / segment.distance
          break unless fraction < 1
          segment[0] = segment.along(fraction)
          sum += alpha * interval
          yielder << case
          when along then [segment[0], sum]
          when angle then [segment[0], segment.diff.angle]
          else segment[0]
          end
          alpha = 1.0
        end
        [alpha - segment.distance / interval, sum + segment.distance]
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
      direction = chunk.last.minus(chunk.first).normalised
      deltas = chunk.map do |point|
        point.minus(chunk.first).cross(direction).abs
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

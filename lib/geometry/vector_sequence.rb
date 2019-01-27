module VectorSequence
  def perps
    ring.map(&:difference).map(&:perp)
  end

  def signed_area
    0.5 * ring.map { |p1, p2| p1.cross p2 }.inject(&:+)
  end

  def clockwise?
    signed_area < 0
  end
  alias hole? clockwise?

  def anticlockwise?
    signed_area >= 0
  end

  def centroid
    ring.map do |p1, p2|
      (p1.plus p2).times(p1.cross p2)
    end.inject(&:plus) / (6.0 * signed_area)
  end

  def convex?
    ring.map(&:difference).ring.all? do |directions|
      directions.inject(&:cross) >= 0
    end
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
    end.inject(hull) do |memo, p3|
      while memo.many? do
        p1, p2 = memo.last(2)
        (p3.minus p1).cross(p2.minus p1) < 0 ? break : memo.pop
      end
      memo << p3
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
    segments.map(&:difference).sum(&:norm)
  end

  def trim(margin)
    start = [margin, 0].max
    stop = path_length - start
    return [] unless start < stop
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

  def crop(length)
    trim(0.5 * (path_length - length))
  end

  def sample_at(interval, along: false, angle: false)
    Enumerator.new do |yielder|
      segments.inject [0.5, 0] do |(alpha, sum), segment|
        loop do
          fraction = alpha * interval / segment.distance
          break unless fraction < 1
          segment[0] = segment.along(fraction)
          sum += alpha * interval
          yielder << case
          when along then [segment[0], sum]
          when angle then [segment[0], segment.difference.angle]
          else segment[0]
          end
          alpha = 1.0
        end
        [alpha - segment.distance / interval, sum + segment.distance]
      end
    end.entries
  end

  def in_sections(count)
    segments.each_slice(count).map do |segments|
      segments.inject do |section, segment|
        section << segment[1]
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

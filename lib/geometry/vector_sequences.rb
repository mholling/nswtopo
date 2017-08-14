module VectorSequences
  def sanitise(closed)
    (closed ? map(&:ring) : map(&:segments)).map do |segments|
      segments.reject do |segment|
        segment.inject(&:==)
      end.map(&:first) + segments.last(closed ? 0 : 1).map(&:last)
    end.reject(&:empty?).reject(&:one?)
  end

  def remove_holes(max_area = true)
    reject do |points|
      area = points.signed_area
      area < 0 && (true == max_area || area.abs < max_area.abs)
    end
  end

  def in_sections(count)
    map(&:segments).map do |segments|
      segments.each_slice(count).map do |segments|
        segments.inject do |section, segment|
          section << segment[1]
        end
      end
    end.flatten(1)
  end

  def at_interval(closed, interval)
    Enumerator.new do |yielder|
      each do |line|
        (closed ? line.ring : line.segments).inject(0.5) do |alpha, segment|
          angle = segment.difference.angle
          while alpha * interval < segment.distance
            segment[0] = segment.along(alpha * interval / segment.distance)
            yielder << [ segment[0], angle ]
            alpha = 1.0
          end
          alpha - segment.distance / interval
        end
      end
    end
  end
end

Array.send :include, VectorSequences

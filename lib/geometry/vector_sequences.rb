module VectorSequences
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

  def sample_at(interval, angles = false)
    [].tap do |result|
      map(&:segments).each do |segments|
        segments.inject(0.5) do |alpha, segment|
          angle = segment.difference.angle if angles
          while alpha * interval < segment.distance
            segment[0] = segment.along(alpha * interval / segment.distance)
            angles ? result << [ segment[0], angle ] : result << segment[0]
            alpha = 1.0
          end
          alpha - segment.distance / interval
        end
      end
    end
  end
end

Array.send :include, VectorSequences

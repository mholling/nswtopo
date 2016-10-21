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
end

Array.send :include, VectorSequences

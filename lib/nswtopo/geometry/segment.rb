module Segment
  def segments
    self[0..-2].zip self[1..-1]
  end

  def ring
    zip rotate
  end

  def difference
    last.minus first
  end

  def distance
    difference.norm
  end

  def along(fraction)
    self[1].times(fraction).plus self[0].times(1.0 - fraction)
  end

  def midpoint
    transpose.map(&:mean)
  end
end

Array.send :include, Segment

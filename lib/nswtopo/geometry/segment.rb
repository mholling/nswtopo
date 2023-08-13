module Segment
  def distance
    last.minus(first).norm
  end

  def along(fraction)
    self[1].times(fraction).plus self[0].times(1.0 - fraction)
  end
end

Array.send :include, Segment

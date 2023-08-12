module Segment
  def diff
    last.minus first
  end

  def distance
    diff.norm
  end

  def along(fraction)
    self[1].times(fraction).plus self[0].times(1.0 - fraction)
  end
end

Array.send :include, Segment

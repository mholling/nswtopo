module SVGPath
  def to_path_data(decimal_digits, *close)
    round(decimal_digits).inject do |memo, point|
      [ *memo, ?L, *point ]
    end.unshift(?M).push(*close).join(?\s)
  end
  
  def to_bezier(k, decimal_digits, *close)
    points = close.any? ? [ last, *self, first ] : [ first, *self, last ]
    midpoints = points.segments.map(&:midpoint)
    distances = points.segments.map(&:distance)
    offsets = midpoints.zip(distances).segments.map(&:transpose).map do |segment, distance|
      segment.along(distance.first / distance.inject(&:+))
    end.zip(self).map(&:difference)
    controls = midpoints.segments.zip(offsets).map do |segment, offset|
      segment.map { |point| [ point, point.plus(offset) ].along(k) }
    end.flatten(1).drop(1).round(decimal_digits).each_slice(2)
    drop(1).round(decimal_digits).zip(controls).map do |point, (control1, control2)|
      [ ?C, *control1, *control2, *point ]
    end.flatten.unshift(?M, *first.round(decimal_digits)).push(*close).join(?\s)
  end
end

Array.send :include, SVGPath

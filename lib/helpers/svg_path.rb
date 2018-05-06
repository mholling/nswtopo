module SVGPath
  def to_path_data(decimal_digits, closed = false, bezier = false)
    bezier = 1 if bezier == true
    map do |line|
      if bezier
        points = closed ? [ line.last, *line, line.first ] : [ line.first, *line, line.last ]
        midpoints = points.segments.map(&:midpoint)
        distances = points.segments.map(&:distance)
        offsets = midpoints.zip(distances).segments.map(&:transpose).map do |segment, distance|
          segment.along(distance.first / distance.inject(&:+))
        end.zip(line).map(&:difference)
        controls = midpoints.segments.zip(offsets).map do |segment, offset|
          segment.map { |point| [ point, point.plus(offset) ].along(bezier) }
        end.flatten(1).drop(1).round(decimal_digits).each_slice(2)
        line.drop(1).round(decimal_digits).zip(controls).map do |point, (control1, control2)|
          [ ?C, *control1, *control2, *point ]
        end.flatten.unshift(?M, *line.first.round(decimal_digits)).push(*(?Z if closed))
      else
        line.round(decimal_digits).inject do |memo, point|
          [ *memo, ?L, *point ]
        end.unshift(?M).push(*(?Z if closed))
      end
    end.flatten.join(?\s)
  end
end

Array.send :include, SVGPath

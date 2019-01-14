module Vector
  def rotate_by(angle)
    cos = Math::cos(angle)
    sin = Math::sin(angle)
    [self[0] * cos - self[1] * sin, self[0] * sin + self[1] * cos]
  end

  def rotate_by!(angle)
    replace rotate_by(angle)
  end

  def rotate_by_degrees(angle)
    rotate_by(angle * Math::PI / 180.0)
  end

  def rotate_by_degrees!(angle)
    replace rotate_by_degrees(angle)
  end

  def plus(other)
    [self, other].transpose.map { |values| values.inject(:+) }
  end

  def minus(other)
    [self, other].transpose.map { |values| values.inject(:-) }
  end

  def dot(other)
    [self, other].transpose.map { |values| values.inject(:*) }.inject(:+)
  end

  def times(scalar)
    map { |value| value * scalar }
  end

  def /(scalar)
    map { |value| value / scalar }
  end

  def negate
    map { |value| -value }
  end

  def to_d
    map(&:to_d)
  end

  def to_f
    map(&:to_f)
  end

  def angle
    Math::atan2 at(1), at(0)
  end

  def norm
    Math::sqrt(dot self)
  end

  def normalised
    self / norm
  end

  def proj(other)
    dot(other) / other.norm
  end

  def perp
    [-self[1], self[0]]
  end

  def cross(other)
    perp.dot other
  end

  def within?(polygon)
    polygon.map do |point|
      point.minus self
    end.ring.inject(0) do |winding, (p0, p1)|
      case
      when p1[1] > 0 && p0[1] <= 0 && p0.minus(p1).cross(p0) >= 0 then winding + 1
      when p0[1] > 0 && p1[1] <= 0 && p1.minus(p0).cross(p0) >= 0 then winding - 1
      when p0[1] == 0 && p1[1] == 0 && p0[0] >= 0 && p1[0] < 0 then winding + 1
      when p0[1] == 0 && p1[1] == 0 && p1[0] >= 0 && p0[0] < 0 then winding - 1
      else winding
      end
    end != 0
  end
end

Array.send :include, Vector

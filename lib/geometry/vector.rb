module Vector
  def rotate_by(angle)
    cos = Math::cos(angle)
    sin = Math::sin(angle)
    [ self[0] * cos - self[1] * sin, self[0] * sin + self[1] * cos ]
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
    [ self, other ].transpose.map { |values| values.inject(:+) }
  end

  def minus(other)
    [ self, other ].transpose.map { |values| values.inject(:-) }
  end

  def dot(other)
    [ self, other ].transpose.map { |values| values.inject(:*) }.inject(:+)
  end
  
  def times(scalar)
    map { |value| value * scalar }
  end
  
  def negate
    map { |value| -value }
  end
  
  def angle
    Math::atan2 at(1), at(0)
  end
  
  def norm
    Math::sqrt(dot self)
  end
  
  def normalised
    times(1.0 / norm)
  end
  
  def proj(other)
    dot(other) / other.norm
  end
  
  def perp
    [ -self[1], self[0] ]
  end
  
  def cross(other)
    perp.dot other
  end
  
  def one_or_many(&block)
    case first
    when Numeric then block.(self)
    else map(&block)
    end
  end
  
  def round(decimal_digits)
    one_or_many do |point|
      point.map { |value| value.round decimal_digits }
    end
  end
end

Array.send :include, Vector

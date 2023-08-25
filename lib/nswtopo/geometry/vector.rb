class Vector
  def initialize(x, y)
    @x, @y = x, y
  end

  def self.[](x, y)
    new x, y
  end

  attr_accessor :x, :y

  def to_ary
    [@x, @y]
  end

  extend Forwardable
  delegate %i[to_json hash each join <=>] => :to_ary

  include Enumerable
  include Comparable
  alias eql? ==

  def inspect
    "{%s, %s}" % [@x, @y]
  end

  def to_d
    Vector[@x.to_d, @y.to_d]
  end

  def to_f
    Vector[@x.to_f, @y.to_f]
  end

  def replace(other)
    tap { @x, @y = other.x, other.y }
  end

  def rotate_by(angle)
    cos = Math::cos(angle)
    sin = Math::sin(angle)
    Vector[@x * cos - @y * sin, @x * sin + @y * cos]
  end

  def rotate_by_degrees(angle)
    rotate_by(angle * Math::PI / 180.0)
  end

  def rotate_by!(angle)
    replace rotate_by(angle)
  end

  def rotate_by_degrees!(angle)
    replace rotate_by_degrees(angle)
  end

  def +(other)
    Vector[@x + other.x, @y + other.y]
  end

  def -(other)
    Vector[@x - other.x, @y - other.y]
  end

  def *(scalar)
    Vector[@x * scalar, @y * scalar]
  end

  def /(scalar)
    Vector[@x / scalar, @y / scalar]
  end

  def +@
    self
  end

  def -@
    self * -1
  end

  def dot(other)
    @x * other.x + @y * other.y
  end

  def perp
    Vector[-@y, @x]
  end

  def cross(other)
    perp.dot other
  end

  def angle
    Math::atan2 @y, @x
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
end

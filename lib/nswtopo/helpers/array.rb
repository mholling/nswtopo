module ArrayHelpers
  def median
    sort[length / 2]
  end

  def mean
    empty? ? nil : inject(&:+) / length
  end

  def many?
    length > 1
  end

  def in_two
    each_slice(1 + [length - 1, 0].max / 2)
  end
end

Array.send :include, ArrayHelpers

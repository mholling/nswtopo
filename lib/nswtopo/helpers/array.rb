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

  def nearby_pairs(closed = false, &block)
    Enumerator.new do |yielder|
      each.with_index do |element1, index|
        (closed ? rotate(index) : drop(index)).drop(1).each do |element2|
          break unless block.call [element1, element2]
          yielder << [element1, element2]
        end
      end
    end
  end
end

Array.send :include, ArrayHelpers

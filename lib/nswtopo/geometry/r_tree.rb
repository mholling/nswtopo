class RTree
  def initialize(nodes, bounds, object = nil)
    @nodes, @bounds, @object = nodes, bounds, object
  end

  def overlaps?(bounds, buffer = 0)
    return false if @bounds.empty?
    return true unless bounds
    bounds.zip(@bounds).all? do |bound1, bound2|
      bound1.zip(bound2.rotate).each.with_index.all? do |limits, index|
        limits.rotate(index).inject(&:-) <= buffer
      end
    end
  end

  def self.load(bounds_objects, &block)
    case
    when block_given? then load bounds_objects.map(&block).zip(bounds_objects)
    when bounds_objects.one? then RTree.new [], *bounds_objects.first
    else
      nodes = bounds_objects.sort_by do |bounds, object|
        bounds[0].inject(&:+)
      end.in_two.map do |bounds_objects|
        bounds_objects.sort_by do |bounds, object|
          bounds[1].inject(&:+)
        end.in_two.map do |bounds_objects|
          load bounds_objects
        end
      end.flatten
      RTree.new nodes, bounds_objects.map(&:first).transpose.map(&:flatten).map(&:minmax)
    end
  end

  def search(bounds, buffer = 0, searched = Set.new)
    Enumerator.new do |yielder|
      next if searched.include? self
      if overlaps? bounds, buffer
        @nodes.each do |node|
          node.search(bounds, buffer, searched).inject(yielder, &:<<)
        end
        yielder << @object if @nodes.empty?
      end
      searched << self
    end
  end

  def bounds_objects(&block)
    @nodes.each do |node|
      node.bounds_objects(&block)
    end
    yield @bounds, @object if @object
  end

  def overlaps(buffer = 0)
    Enumerator.new do |yielder|
      bounds_objects do |bounds, object|
        search(bounds, buffer).each do |other|
          yielder << [object, other]
        end
      end
    end
  end
end

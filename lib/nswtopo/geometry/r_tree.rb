class RTree
  def initialize(nodes, bounds, object = nil)
    @nodes, @bounds, @object = nodes, bounds, object
  end

  def overlaps?(bounds, buffer)
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
      bounds_objects.sort_by do |bounds, object|
        bounds[0].inject(&:+)
      end.then do |bounds_object|
        bounds_objects.each_slice(1 + [bounds_objects.length - 1, 0].max / 2)
      end.flat_map do |bounds_objects|
        bounds_objects.sort_by do |bounds, object|
          bounds[1].inject(&:+)
        end.then do |bounds_objects|
          bounds_objects.each_slice(1 + [bounds_objects.length - 1, 0].max / 2)
        end.map do |bounds_objects|
          load bounds_objects
        end
      end.then do |nodes|
        RTree.new nodes, bounds_objects.map(&:first).transpose.map(&:flatten).map(&:minmax)
      end
    end
  end

  def search(bounds, buffer: 0, searched: Set.new)
    Enumerator.new do |yielder|
      next if searched.include? self
      if overlaps? bounds, buffer
        @nodes.each do |node|
          node.search(bounds, buffer: buffer, searched: searched).inject(yielder, &:<<)
        end
        yielder << @object if @nodes.empty?
      end
      searched << self
    end
  end

  def each(&block)
    @nodes.each do |node|
      node.each(&block)
    end
    yield @bounds, @object if @object
  end
end

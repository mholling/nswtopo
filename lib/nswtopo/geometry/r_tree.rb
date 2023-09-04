class RTree
  using Helpers

  def initialize(nodes, bounds, object = nil)
    @nodes, @bounds, @object = nodes, bounds, object
  end

  attr_reader :bounds

  def overlaps?(bounds, buffer)
    return false if @bounds.empty?
    return true unless bounds
    bounds.zip(@bounds).all? do |(min1, max1), (min2, max2)|
      max1 + buffer >= min2 && max2 + buffer >= min1
    end
  end

  def self.load(objects, &bounds)
    load! objects.map(&bounds).zip(objects)
  end

  def self.load!(bounds_objects, range = 0...bounds_objects.length)
    return RTree.new([], *bounds_objects[range.begin]) if range.one?
    bounds_objects.median_partition!(range) do |bounds, object|
      bounds[0].sum
    end.flat_map do |range|
      bounds_objects.median_partition!(range) do |bounds, object|
        bounds[1].sum
      end
    end.filter_map do |range|
      load!(bounds_objects, range) if range.any?
    end.then do |nodes|
      RTree.new nodes, nodes.map(&:bounds).transpose.map(&:flatten).map(&:minmax)
    end
  end

  def search(bounds, buffer = 0)
    Enumerator.new do |yielder|
      if overlaps? bounds, buffer
        @nodes.each do |node|
          node.search(bounds, buffer).each(&yielder)
        end
        yielder << @object if @nodes.empty?
      end
    end
  end

  def each(&block)
    @nodes.each do |node|
      node.each(&block)
    end
    yield @bounds, @object if @object
  end
end

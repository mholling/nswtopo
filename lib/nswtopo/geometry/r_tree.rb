class RTree
  def initialize(nodes, bounds, object = nil)
    @nodes, @bounds, @object = nodes, bounds, object
  end

  def overlaps?(bounds)
    return false if @bounds.empty?
    return true unless bounds
    bounds.zip(@bounds).all? do |bound1, bound2|
      bound1.zip(bound2.rotate).each.with_index.all? do |limits, index|
        limits.rotate(index).inject(&:<=)
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

  def search(bounds, searched = Set.new)
    Enumerator.new do |yielder|
      unless searched.include? self
        if overlaps? bounds
          @nodes.each do |node|
            node.search(bounds, searched).each { |object| yielder << object }
          end
          yielder << @object if @nodes.empty?
        end
        searched << self
      end
    end
  end
end

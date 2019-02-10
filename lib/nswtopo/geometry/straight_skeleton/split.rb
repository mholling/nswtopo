module StraightSkeleton
  class Split
    include InteriorNode

    def initialize(nodes, point, travel, source, node)
      @original, @nodes, @point, @travel, @source, @normal = self, nodes, point, travel, source, node.normals[1]
    end

    attr_reader :source

    def viable?
      return false unless @source.active?
      @edge = @nodes.track(@normal).find do |edge|
        (n00, n01), (n10, n11) = edge.map(&:normals)
        p0, p1 = edge.map(&:point)
        next if point.minus(p0).cross(n00 ? n00.plus(n01) : n01) < 0
        next if point.minus(p1).cross(n11 ? n11.plus(n10) : n10) > 0
        true
      end
    end

    def split!(index, &block)
      @neighbours = [@source.neighbours[index], @edge[1-index]].rotate index
      @neighbours.inject(&:equal?) ? block.call(prev, prev.is_a?(Collapse) ? 1 : 0) : insert! if @neighbours.any?
    end

    def replace!(&block)
      dup.split!(0, &block)
      dup.split!(1, &block)
      block.call @source
    end
  end
end

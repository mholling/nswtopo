module StraightSkeleton
  class Collapse
    include InteriorNode

    def initialize(nodes, point, travel, sources)
      @original, @nodes, @point, @travel, @sources = self, nodes, point, travel, sources
    end

    def viable?
      @sources.all?(&:active?)
    end

    def replace!(&block)
      @neighbours = [@sources[0].prev, @sources[1].next]
      @neighbours.inject(&:==) ? block.call(prev) : insert! if @neighbours.any?
      @sources.each(&block)
    end

    alias splits? terminal?
  end
end

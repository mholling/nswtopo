module NSWTopo
  module Labels
    class Barriers
      def initialize
        @barriers, @cache = [], Hash[]
      end

      extend Forwardable
      delegate :<< => :@barriers

      def to_proc
        @index ||= RTree.load(@barriers.flat_map(&:explode), &:bounds)
        @proc ||= lambda do |label_hull, buffer|
          @cache[[buffer, label_hull.coordinates]] ||= @index.search(label_hull.bounds, buffer).with_object Set[] do |barrier_hull, barriers|
            next if barriers === barrier_hull.source
            next unless ConvexHulls.overlap?(barrier_hull, label_hull, buffer)
            barriers << barrier_hull.source
          end
        end
      end
    end
  end
end

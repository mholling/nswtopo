module NSWTopo
  module GeoJSON
    class Polygon
      delegate %i[area skeleton centres centrepoints centrelines buffer centroids samples] => :multi

      def validate!
        @coordinates.inject(false) do |hole, ring|
          ring.reverse! if hole ^ ring.hole?
          true
        end
      end

      def bounds
        @coordinates.first.transpose.map(&:minmax)
      end
    end
  end
end

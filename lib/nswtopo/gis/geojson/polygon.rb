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

      def wkt
        @coordinates.map do |ring|
          ring.map do |point|
            point.join(" ")
          end.join(", ").prepend("(").concat(")")
        end.join(", ").prepend("POLYGON (").concat(")")
      end
    end
  end
end

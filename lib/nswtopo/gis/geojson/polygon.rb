module NSWTopo
  module GeoJSON
    class Polygon
      delegate %i[area skeleton centres centrepoints centrelines buffer centroids samples] => :multi

      def bounds
        @coordinates.first.transpose.map(&:minmax)
      end
    end
  end
end

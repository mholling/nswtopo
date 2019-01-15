module NSWTopo
  module GeoJSON
    class Polygon
      def area
        @coordinates.sum(&:signed_area)
      end
    end
  end
end

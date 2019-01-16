module NSWTopo
  module GeoJSON
    class Polygon
      def area
        @coordinates.sum(&:signed_area)
      end

      delegate %i[skeleton centres centrepoints centrelines buffer] => :multi
    end
  end
end

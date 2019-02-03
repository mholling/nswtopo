module NSWTopo
  module GeoJSON
    class Point
      def bounds
        @coordinates.zip.map(&:minmax)
      end
    end
  end
end

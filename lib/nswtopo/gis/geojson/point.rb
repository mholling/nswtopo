module NSWTopo
  module GeoJSON
    class Point
      def self.vectorise!(coordinates)
        Vector === coordinates ? coordinates : Vector[*coordinates]
      end

      def bounds
        @coordinates.zip.map(&:minmax)
      end
    end
  end
end

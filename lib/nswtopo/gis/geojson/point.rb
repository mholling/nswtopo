module NSWTopo
  module GeoJSON
    class Point
      def self.vectorise!(coordinates)
        Vector === coordinates ? coordinates : Vector[*coordinates]
      end

      def bounds
        @coordinates.zip.map(&:minmax)
      end

      delegate :rotate_by_degrees! => :@coordinates
    end
  end
end

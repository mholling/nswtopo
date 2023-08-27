module NSWTopo
  module GeoJSON
    class Point
      def self.vectorise!(coordinates)
        Vector === coordinates ? coordinates : Vector[*coordinates]
      end

      def bounds
        zip.map(&:minmax)
      end

      def empty?
        false
      end

      def rotate_by_degrees(angle)
        Point.new @coordinates.rotate_by_degrees(angle), @properties
      end
    end
  end
end

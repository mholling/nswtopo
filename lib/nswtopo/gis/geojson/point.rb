module NSWTopo
  module GeoJSON
    class Point
      def sanitise!
        @coordinates = Vector[*@coordinates] unless Vector === @coordinates
      end

      alias freeze! freeze

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

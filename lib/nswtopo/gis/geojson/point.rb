module NSWTopo
  module GeoJSON
    class Point
      def self.[](coordinates, properties = nil, &block)
        new(coordinates, properties) do
          @coordinates = Vector[*@coordinates] unless Vector === @coordinates
          block.call self if block_given?
        end
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

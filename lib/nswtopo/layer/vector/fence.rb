module NSWTopo
  module Vector
    class Fence
      def initialize(features, buffer)
        @features, @buffer = features, buffer
      end
      attr_reader :buffer

      def each
        @features.flat_map do |feature|
          case feature
          when GeoJSON::Point
            [[feature.coordinates] * 2]
          when GeoJSON::LineString
            feature.coordinates.segments
          when GeoJSON::Polygon
            feature.coordinates.flat_map(&:segments)
          end
        end.each
      end
    end
  end
end

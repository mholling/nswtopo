module NSWTopo
  module Labels
    class Barrier
      class Segment
        def initialize(segment, barrier)
          @segment, @barrier = segment, barrier
          @bounds = @segment.transpose.map(&:minmax).map do |min, max|
            [min - barrier.buffer, max + barrier.buffer]
          end
        end
        attr_reader :barrier, :bounds

        def conflicts_with?(segment, buffer: 0)
          [@segment, segment].overlap?(@barrier.buffer + buffer)
        end
      end

      def initialize(feature, buffer)
        @feature, @buffer = feature, buffer
      end
      attr_reader :buffer

      def segments
        case @feature
        when GeoJSON::Point
          [[@feature.coordinates] * 2]
        when GeoJSON::LineString
          @feature.coordinates.segments
        when GeoJSON::Polygon
          @feature.coordinates.flat_map do |coordinates|
            coordinates.segments
          end
        end.map do |segment|
          Segment.new segment, self
        end
      end
    end
  end
end

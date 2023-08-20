module NSWTopo
  module Labels
    class Barrier
      class Segment
        def initialize(segment, barrier)
          @segment, @barrier = segment, barrier
          @bounds = @segment.bounds.map do |min, max|
            [min - barrier.buffer, max + barrier.buffer]
          end
          @segment = GeoJSON::LineString.new [@segment.coordinates] if GeoJSON::Point === @segment
        end
        attr_reader :barrier, :bounds

        def conflicts_with?(geometry, buffer: 0)
          case geometry
          when GeoJSON::MultiLineString # collection of convex hulls (for barrier/point-label conflicts)
            geometry.explode.any? do |ring|
              @segment.convex_overlaps? ring, buffer: @barrier.buffer + buffer
            end
          when Array # pair of points forming a baseline segment (for barrier/line-label conflicts)
            segment = GeoJSON::LineString.new geometry
            @segment.convex_overlaps? segment, buffer: @barrier.buffer + buffer
          end
        end
      end

      def initialize(feature, buffer)
        @feature, @buffer = feature, buffer
      end
      attr_reader :buffer

      def segments
        case @feature
        when GeoJSON::Point
          @feature
        when GeoJSON::LineString
          @feature.dissolve_segments
        when GeoJSON::Polygon
          @feature.dissolve_segments
        end.explode.map do |segment|
          Segment.new segment, self
        end
      end
    end
  end
end

module NSWTopo
  module Labels
    class Fence
      def initialize(segment, buffer: 0, index:)
        @segment, @buffer, @index = segment, buffer, index
      end
      attr_reader :index

      def bounds
        @segment.transpose.map(&:minmax).map do |min, max|
          [min - @buffer, max + @buffer]
        end
      end

      def conflicts_with?(segment, buffer = 0)
        [@segment, segment].overlap?(@buffer + buffer)
      end
    end
  end
end

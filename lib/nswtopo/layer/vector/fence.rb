module NSWTopo
  module Vector
    class Fence
      def initialize(features, buffer)
        @features, @buffer = features, buffer
      end
      attr_reader :features, :buffer
    end
  end
end

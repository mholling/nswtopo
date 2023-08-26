module NSWTopo
  module Labels
    class Barrier
      def initialize(feature, buffer)
        @hulls = Hull.from_geometry feature, buffer: buffer, owner: self
      end

      attr_reader :hulls
    end
  end
end

module NSWTopo
  module Labels
    class ConvexHull < GeoJSON::LineString
      def initialize(source, coordinates)
        @source = source
        super coordinates
      end

      attr_reader :source
    end
  end
end

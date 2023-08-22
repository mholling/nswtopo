module NSWTopo
  module Labels
    class Barrier
      def initialize(feature, buffer)
        @hulls = case feature
        when GeoJSON::Point
          feature
        when GeoJSON::LineString
          feature.dissolve_segments
        when GeoJSON::Polygon
          feature.dissolve_segments
        end.explode.map do |feature|
          Hull.new feature, buffer, owner: self
        end
      end

      attr_reader :hulls
    end
  end
end

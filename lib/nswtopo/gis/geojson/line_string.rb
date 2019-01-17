module NSWTopo
  module GeoJSON
    class LineString
      def length
        @coordinates.path_length
      end
    end
  end
end

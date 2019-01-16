module NSWTopo
  module GeoJSON
    class LineString
      def length
        @coordinates.path_length
      end

      delegate %i[offset buffer smooth] => :multi
    end
  end
end

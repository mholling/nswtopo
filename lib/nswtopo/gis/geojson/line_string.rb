module NSWTopo
  module GeoJSON
    class LineString
      delegate %i[length offset buffer smooth samples] => :multi

      def bounds
        @coordinates.transpose.map(&:minmax)
      end
    end
  end
end

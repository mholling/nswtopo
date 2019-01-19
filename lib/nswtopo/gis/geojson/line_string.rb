module NSWTopo
  module GeoJSON
    class LineString
      delegate %i[length offset buffer smooth samples] => :multi
    end
  end
end

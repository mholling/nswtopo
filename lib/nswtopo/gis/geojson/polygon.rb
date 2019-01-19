module NSWTopo
  module GeoJSON
    class Polygon
      delegate %i[area skeleton centres centrepoints centrelines buffer centroids samples] => :multi
    end
  end
end

module NSWTopo
  class OverlaySource
    include VectorRenderer
    attr_reader :path
    
    def initialize(name, params)
      @name, @params = name, params
      @path = Pathname.new(params["path"]).expand_path
    end
    
    def features(map)
      raise BadLayerError.new("#{name} file not found at #{path}") unless path.exist?
      gps = GPS.new(path)
      [ [ :waypoints, 0 ], [ :tracks, 1 ], [ :areas, 2 ] ].map do |type, dimension|
        gps.send(type).map do |coords, name|
          point_or_line = map.coords_to_mm map.reproject_from_wgs84(coords)
          [ dimension, [ point_or_line ], name ]
        end
      end.flatten(1)
    rescue BadGpxKmlFile => e
      raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
    end
  end
end

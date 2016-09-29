module NSWTopo
  module NoCreate
    def create(map)
      raise BadLayerError.new("#{name} file not found at #{path}")
    end
  end
end

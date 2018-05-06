module NSWTopo
  class CanvasSource
    include RasterRenderer
    
    def create()
      raise BadLayerError.new("canvas image not found at #{path}") unless path.exist?
    end
    
    def resolution_for(map)
      raise BadLayerError.new("canvas image not found at #{path}") unless path.exist?
      return params["resolution"] if params["resolution"]
      pixels_per_centimeter = %x[convert "#{path}" -units PixelsPerCentimeter -format "%[resolution.x]" info:]
      raise BadLayerError.new("bad canvas image at #{path}") unless $?.success?
      map.scale * 0.01 / pixels_per_centimeter.to_f
    end
  end
end

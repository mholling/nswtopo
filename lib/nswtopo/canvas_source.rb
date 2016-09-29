module NSWTopo
  class CanvasSource < Source
    include RasterRenderer
    include NoCreate
    
    def resolution_for(map)
      return params["resolution"] if params["resolution"]
      raise BadLayerError.new("canvas image not found at #{path}") unless path.exist?
      pixels_per_centimeter = %x[convert "#{path}" -units PixelsPerCentimeter -format "%[resolution.x]" info:]
      raise BadLayerError.new("bad canvas image at #{path}") unless $?.success?
      map.scale * 0.01 / pixels_per_centimeter.to_f
    end
  end
end

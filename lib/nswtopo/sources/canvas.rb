module NSWTopo
  class CanvasSource
    include RasterRenderer

    def create
      raise BadLayerError.new("canvas image not found at #{path}") unless path.exist?
    end

    def resolution
      @resolution ||= if params["resolution"]
        params["resolution"]
      else
        raise BadLayerError.new("canvas image not found at #{path}") unless path.exist?
        pixels_per_centimeter = %x[convert "#{path}" -units PixelsPerCentimeter -format "%[resolution.x]" info:]
        raise BadLayerError.new("bad canvas image at #{path}") unless $?.success?
        MAP.scale * 0.01 / pixels_per_centimeter.to_f
      end
    end
  end
end

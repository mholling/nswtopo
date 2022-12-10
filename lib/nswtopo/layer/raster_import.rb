module NSWTopo
  module RasterImport
    def get_raster(temp_dir)
      crop_path = temp_dir / "crop.tif"
      @path = Pathname(@path).expand_path(@source ? @source.parent : Pathname.pwd)

      json = OS.gdalinfo "-json", @path
      palette = JSON.parse(json)["bands"].any? do |band|
        "Palette" == band["colorInterpretation"]
      end

      args = ["-expand", "rgba"] if palette
      OS.gdal_translate *args, @path, crop_path

      return crop_path
    rescue OS::Error
      raise "invalid raster file: #{@path}"
    end
  end
end

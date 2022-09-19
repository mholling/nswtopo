module NSWTopo
  module RasterImport
    def get_raster(temp_dir)
      crop_path = temp_dir / "crop.tif"
      @path = Pathname(@path).expand_path(@source ? @source.parent : Pathname.pwd)

      json = OS.gdalinfo "-json", @path
      palette = JSON.parse(json)["bands"].any? do |band|
        "Palette" == band["colorInterpretation"]
      end

      projection = Projection.new(@path)
      args = ["-projwin", *@map.projwin(projection), @path, crop_path]
      args += ["-expand", "rgba", *args] if palette
      OS.gdal_translate *args

      @resolution ||= @map.get_raster_resolution(crop_path)
      return @resolution, crop_path
    rescue OS::Error
      raise "invalid raster file: #{@path}"
    end
  end
end

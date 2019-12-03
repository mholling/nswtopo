module NSWTopo
  module Import
    include Raster

    def get_raster(temp_dir)
      crop_path = temp_dir / "crop.tif"
      Dir.chdir(@source ? @source.parent : Pathname.pwd) do
        json = OS.gdalinfo "-json", @path
        palette = JSON.parse(json)["bands"].any? do |band|
          "Palette" == band["colorInterpretation"]
        end

        projection = Projection.new(@path)
        args = ["-projwin", *@map.projwin(projection), @path, crop_path]
        args += ["-expand", "rgba", *args] if palette
        OS.gdal_translate *args
      rescue OS::Error
        raise "invalid raster file: #{@path}"
      end

      return Numeric === @resolution ? @resolution : @map.get_raster_resolution(crop_path), crop_path
    end
  end
end

module NSWTopo
  module RasterImport
    def get_raster(temp_dir)
      @path = Pathname(@path).expand_path(@source ? @source.parent : Pathname.pwd)
      temp_dir.join("import.vrt").tap do |vrt_path|
        JSON.parse(OS.gdalinfo "-json", @path).fetch("bands").any? do |band|
          "Palette" == band["colorInterpretation"]
        end.then do |palette|
          args = ["-expand", "rgba"] if palette
          OS.gdal_translate *args, @path, vrt_path
        end
      end
    rescue OS::Error
      raise "invalid raster file: #{@path}"
    end
  end
end

module NSWTopo
  module Import
    include Raster
    CREATE = %w[resolution]

    def get_raster(temp_dir)
      crop_path = temp_dir / "crop.tif"

      json = begin
        OS.gdalinfo "-json", @path
      rescue OS::Error
        raise "invalid raster file: #{@path}"
      end
      palette = JSON.parse(json)["bands"].any? do |band|
        "Palette" == band["colorInterpretation"]
      end

      projection = Projection.new(@path)
      args = [ "-projwin", *@map.projwin(projection), @path, crop_path ]
      args = [ "-expand", "rgba", *args ] if palette
      OS.gdal_translate *args

      return Numeric === @resolution ? @resolution : get_resolution(crop_path), crop_path
    end
  end
end

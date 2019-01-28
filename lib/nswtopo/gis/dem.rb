module NSWTopo
  module DEM
    def get_dem(temp_dir, bounds, dem_path)
      txt_path = temp_dir / "dem.txt"
      vrt_path = temp_dir / "dem.vrt"

      Dir.chdir(@source ? @source.parent : Pathname.pwd) do
        GDALGlob.rasters @path
      end.tap do |rasters|
        raise "no elevation data found at specified path" if rasters.none?
      end.group_by do |path, info|
        Projection.new info.dig("coordinateSystem", "wkt")
      end.map.with_index do |(projection, rasters), index|
        raise "DEM data not in planar projection with metre units" unless projection.proj4.split(?\s).any?("+units=m")

        paths, resolutions = rasters.map do |path, info|
          [path, info["geoTransform"].values_at(1, 2).norm]
        end.sort_by(&:last).transpose

        txt_path.write paths.reverse.join(?\n)
        @resolution ||= resolutions.first

        indexed_dem_path = temp_dir / "dem.#{index}.tif"
        OS.gdalbuildvrt "-overwrite", "-input_file_list", txt_path, vrt_path
        OS.gdalwarp "-t_srs", @map.projection, "-te", *bounds.transpose.flatten, "-tr", @resolution, @resolution, "-r", "bilinear", vrt_path, indexed_dem_path
        indexed_dem_path
      end.tap do |dem_paths|
        txt_path.write dem_paths.join(?\n)
        OS.gdalbuildvrt "-overwrite", "-input_file_list", txt_path, vrt_path
        OS.gdal_translate vrt_path, dem_path
      end
    end
  end
end

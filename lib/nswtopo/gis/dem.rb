module NSWTopo
  module DEM
    include GDALGlob, Log

    def get_dem(temp_dir, dem_path)
      txt_path = temp_dir / "dem.txt"
      vrt_path = temp_dir / "dem.vrt"
      te = @map.bounds(margin: margin).transpose.flatten

      Dir.chdir(@source ? @source.parent : Pathname.pwd) do
        log_update "%s: examining DEM" % @name
        gdal_rasters @path do |index, total|
          log_update "%s: examining DEM file %i of %i" % [@name, index, total]
        end
      end.tap do |rasters|
        raise "no elevation data found at specified path" if rasters.none?
        log_update "%s: extracting DEM raster" % @name
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
        OS.gdalwarp "-t_srs", @map.projection, "-te", *te, "-tr", @resolution, @resolution, "-r", "bilinear", vrt_path, indexed_dem_path
        indexed_dem_path
      end.tap do |dem_paths|
        txt_path.write dem_paths.join(?\n)
        OS.gdalbuildvrt "-overwrite", "-input_file_list", txt_path, vrt_path
        OS.gdal_translate vrt_path, dem_path
      end
    end

    def blur_dem(dem_path, blur_path)
      sigma = @smooth * @map.scale / 1000.0
      half = (3 * sigma / @resolution).ceil

      coeffs = (-half..half).map do |n|
        n * @resolution / sigma
      end.map do |x|
        Math::exp(-x**2)
      end

      vrt = OS.gdalbuildvrt "/vsistdout/", dem_path
      xml = REXML::Document.new vrt
      xml.elements.each("//ComplexSource") do |complex_source|
        kernel_filtered_source = complex_source.parent.add_element("KernelFilteredSource")
        complex_source.elements.each("SourceFilename|OpenOptions|SourceBand|SourceProperties|SrcRect|DstRect") do |element|
          kernel_filtered_source.add_element element
        end
        kernel = kernel_filtered_source.add_element("Kernel", "normalized" => 1)
        kernel.add_element("Size").text = coeffs.size
        kernel.add_element("Coefs").text = coeffs.join ?\s
        complex_source.parent.delete complex_source
      end

      log_update "%s: smoothing DEM raster" % @name
      OS.gdal_translate "/vsistdin/", blur_path do |stdin|
        stdin.write xml
      end
    end
  end
end

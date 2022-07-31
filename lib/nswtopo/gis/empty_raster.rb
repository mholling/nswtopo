module NSWTopo
  module EmptyRaster
    extend self

    def write(path, projection:, dimensions:, top_left:, resolution:, angle: 0)
      vrt = REXML::Document.new
      vrt.add_element("VRTDataset", "rasterXSize" => dimensions[0], "rasterYSize" => dimensions[1]).tap do |dataset|
        geotransform = WorldFile.geotransform(top_left: top_left, resolution: resolution, angle: angle).join(", ")
        dataset.add_element("SRS").add_text(projection.wkt_simple)
        dataset.add_element("GeoTransform").add_text(geotransform)
        dataset.add_element("VRTRasterBand", "dataType" => "Byte", "band" => 1).add_element("ColorInterp").add_text("Red")
        dataset.add_element("VRTRasterBand", "dataType" => "Byte", "band" => 2).add_element("ColorInterp").add_text("Green")
        dataset.add_element("VRTRasterBand", "dataType" => "Byte", "band" => 3).add_element("ColorInterp").add_text("Blue")
        dataset.add_element("VRTRasterBand", "dataType" => "Byte", "band" => 4).add_element("ColorInterp").add_text("Alpha")
      end
      OS.gdal_translate "/vsistdin/", path do |stdin|
        stdin.write vrt
      end
    end
  end
end

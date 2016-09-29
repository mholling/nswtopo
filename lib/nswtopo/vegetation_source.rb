module NSWTopo
  class VegetationSource < Source
    include RasterRenderer
    
    def get_raster(map, dimensions, resolution, temp_dir)
      src_path = temp_dir + "#{name}.txt"
      vrt_path = temp_dir + "#{name}.vrt"
      tif_path = temp_dir + "#{name}.tif"
      tfw_path = temp_dir + "#{name}.tfw"
      clut_path = temp_dir + "#{name}-clut.png"
      mask_path = temp_dir + "#{name}-mask.png"
      
      [ *params["path"] ].map do |path|
        Pathname.glob path
      end.inject([], &:+).map(&:expand_path).tap do |paths|
        raise BadLayerError.new("no vegetation data file specified") if paths.empty?
      end.join(?\n).tap do |path_list|
        File.write src_path, path_list
      end
      %x[gdalbuildvrt -input_file_list "#{src_path}" "#{vrt_path}"]
      
      map.write_world_file tfw_path, resolution
      %x[convert -size #{dimensions.join ?x} canvas:white -type Grayscale -depth 8 "#{tif_path}"]
      %x[gdalwarp -t_srs "#{map.projection}" "#{vrt_path}" "#{tif_path}"]
      
      low, high, factor = { "low" => 0, "high" => 100, "factor" => 0.0 }.merge(params["contrast"] || {}).values_at("low", "high", "factor")
      %x[convert -size 1x256 canvas:black "#{clut_path}"]
      params["mapping"].map do |key, value|
        "j==#{key} ? %.5f : u" % (value < low ? 0.0 : value > high ? 1.0 : (value - low).to_f / (high - low))
      end.each do |fx|
        %x[mogrify -fx "#{fx}" "#{clut_path}"]
      end
      %x[mogrify -sigmoidal-contrast #{factor}x50% "#{clut_path}"]
      %x[convert "#{tif_path}" "#{clut_path}" -clut "#{mask_path}"]
      
      woody, nonwoody = params["colour"].values_at("woody", "non-woody")
      density = 0.01 * map.scale / resolution
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:"#{nonwoody}" #{OP} "#{mask_path}" -background "#{woody}" -alpha Shape #{CP} -composite "#{raster_path}"]
      end
    end
    
    def embed_image(temp_dir)
      raise BadLayerError.new("vegetation raster image not found at #{path}") unless path.exist?
      path
    end
  end
end

module NSWTopo
  class TiledServer < Source
    include RasterRenderer
    
    def get_raster(map, dimensions, resolution, temp_dir)
      src_path = temp_dir + "#{name}.txt"
      vrt_path = temp_dir + "#{name}.vrt"
      tif_path = temp_dir + "#{name}.tif"
      tfw_path = temp_dir + "#{name}.tfw"
      
      tiles(map, resolution, temp_dir).each do |tile_bounds, tile_resolution, tile_path|
        topleft = [ tile_bounds.first.min, tile_bounds.last.max ]
        WorldFile.write topleft, tile_resolution, 0, Pathname.new("#{tile_path}w")
      end.map(&:last).join(?\n).tap do |path_list|
        File.write src_path, path_list
        %x[gdalbuildvrt -input_file_list "#{src_path}" "#{vrt_path}"] unless path_list.empty?
      end

      density = 0.01 * map.scale / resolution
      %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:black -type TrueColor -depth 8 "#{tif_path}"]
      if vrt_path.exist?
        map.write_world_file tfw_path, resolution
        resample = params["resample"] || "cubic"
        projection = Projection.new(params["projection"])
        %x[gdalwarp -s_srs "#{projection}" -t_srs "#{map.projection}" -r #{resample} "#{vrt_path}" "#{tif_path}"]
      end
      
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert -quiet "#{tif_path}" "#{raster_path}"]
      end
    end
  end
end

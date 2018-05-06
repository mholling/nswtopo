module NSWTopo
  class ImportSource
    include RasterRenderer
    
    def resolution_for(map)
      import_path = Pathname.new(params["path"]).expand_path
      Math::sqrt(0.5) * [ [ 0, 0 ], [ 1, 1 ] ].map do |point|
        %x[echo #{point.join ?\s} | gdaltransform "#{import_path}" -t_srs "#{map.projection}"].tap do |output|
          raise BadLayerError.new("couldn't use georeferenced file at #{import_path}") unless $?.success?
        end.split(?\s)[0..1].map(&:to_f)
      end.distance
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      import_path = Pathname.new(params["path"]).expand_path
      source_path = temp_dir + "source.tif"
      tfw_path = temp_dir + "#{name}.tfw"
      tif_path = temp_dir + "#{name}.tif"
      
      density = 0.01 * map.scale / resolution
      map.write_world_file tfw_path, resolution
      %x[convert -size #{dimensions.join ?x} canvas:none -type TrueColorMatte -depth 8 -units PixelsPerCentimeter -density #{density} "#{tif_path}"]
      %x[gdal_translate -expand rgba "#{import_path}" "#{source_path}"]
      %x[gdal_translate "#{import_path}" "#{source_path}"] unless $?.success?
      raise BadLayerError.new("couldn't use georeferenced file at #{import_path}") unless $?.success?
      %x[gdalwarp -t_srs "#{map.projection}" -r bilinear "#{source_path}" "#{tif_path}"]
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert "#{tif_path}" -quiet "#{raster_path}"]
      end
    end
  end
end

module NSWTopo
  module KMZ
    TILE_SIZE = 512
    TILT = 40 * Math::PI / 180.0
    FOV = 30 * Math::PI / 180.0
    
    def self.style
      lambda do |style|
        style.add_element("ListStyle", "id" => "hideChildren").tap do |list_style|
          list_style.add_element("listItemType").text = "checkHideChildren"
        end
      end
    end
    
    def self.lat_lon_box(bounds)
      lambda do |box|
        [ %w[west east south north], bounds.flatten ].transpose.each do |limit, value|
          box.add_element(limit).text = value
        end
      end
    end
    
    def self.region(bounds, topmost = false)
      lambda do |region|
        region.add_element("Lod").tap do |lod|
          lod.add_element("minLodPixels").text = topmost ? 0 : TILE_SIZE / 2
          lod.add_element("maxLodPixels").text = -1
        end
        region.add_element("LatLonAltBox").tap(&lat_lon_box(bounds))
      end
    end
    
    def self.network_link(bounds, path)
      lambda do |network|
        network.add_element("Region").tap(&region(bounds))
        network.add_element("Link").tap do |link|
          link.add_element("href").text = path
          link.add_element("viewRefreshMode").text = "onRegion"
          link.add_element("viewFormat")
        end
      end
    end
    
    def self.build(map, ppi, image_path, kmz_path)
      wgs84_bounds = map.wgs84_bounds
      degrees_per_pixel = 180.0 * map.resolution_at(ppi) / Math::PI / EARTH_RADIUS
      dimensions = wgs84_bounds.map { |bound| bound.reverse.inject(:-) / degrees_per_pixel }
      max_zoom = Math::log2(dimensions.max).ceil - Math::log2(TILE_SIZE).to_i
      topleft = [ wgs84_bounds.first.min, wgs84_bounds.last.max ]
      
      Dir.mktmppath do |temp_dir|
        file_name = image_path.basename
        source_path = temp_dir + file_name
        worldfile_path = temp_dir + "#{file_name}w"
        FileUtils.cp image_path, source_path
        map.write_world_file worldfile_path, map.resolution_at(ppi)
        
        pyramid = (0..max_zoom).map do |zoom|
          resolution = degrees_per_pixel * 2**(max_zoom - zoom)
          degrees_per_tile = resolution * TILE_SIZE
          counts = wgs84_bounds.map { |bound| (bound.reverse.inject(:-) / degrees_per_tile).ceil }
          dimensions = counts.map { |count| count * TILE_SIZE }
          
          tfw_path = temp_dir + "zoom-#{zoom}.tfw"
          tif_path = temp_dir + "zoom-#{zoom}.tif"
          %x[convert -size #{dimensions.join ?x} canvas:none -type TrueColorMatte -depth 8 "#{tif_path}"]
          WorldFile.write topleft, resolution, 0, tfw_path
          
          %x[gdalwarp -s_srs "#{map.projection}" -t_srs "#{Projection.wgs84}" -r bilinear -dstalpha "#{source_path}" "#{tif_path}"]
          
          indices_bounds = [ topleft, counts, [ :+, :- ] ].transpose.map do |coord, count, increment|
            boundaries = (0..count).map { |index| coord.send increment, index * degrees_per_tile }
            [ boundaries[0..-2], boundaries[1..-1] ].transpose.map(&:sort)
          end.map do |tile_bounds|
            tile_bounds.each.with_index.to_a
          end.inject(:product).map(&:transpose).map do |tile_bounds, indices|
            { indices => tile_bounds }
          end.inject({}, &:merge)
          $stdout << "\r  resizing image pyramid (#{100 * (2**(zoom + 1) - 1) / (2**(max_zoom + 1) - 1)}%)"
          { zoom => indices_bounds }
        end.inject({}, &:merge)
        puts
        
        kmz_dir = temp_dir + map.name
        kmz_dir.mkdir
        
        pyramid.map do |zoom, indices_bounds|
          zoom_dir = kmz_dir + zoom.to_s
          zoom_dir.mkdir
          
          tif_path = temp_dir + "zoom-#{zoom}.tif"
          indices_bounds.map do |indices, tile_bounds|
            index_dir = zoom_dir + indices.first.to_s
            index_dir.mkdir unless index_dir.exist?
            tile_kml_path = index_dir + "#{indices.last}.kml"
            tile_png_name = "#{indices.last}.png"
            
            xml = REXML::Document.new
            xml << REXML::XMLDecl.new(1.0, "UTF-8")
            xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1").tap do |kml|
              kml.add_element("Document").tap do |document|
                document.add_element("Style").tap(&style)
                document.add_element("Region").tap(&region(tile_bounds, true))
                document.add_element("GroundOverlay").tap do |overlay|
                  overlay.add_element("drawOrder").text = zoom
                  overlay.add_element("Icon").add_element("href").text = tile_png_name
                  overlay.add_element("LatLonBox").tap(&lat_lon_box(tile_bounds))
                end
                if zoom < max_zoom
                  indices.map do |index|
                    [ 2 * index, 2 * index + 1 ]
                  end.inject(:product).select do |subindices|
                    pyramid[zoom + 1][subindices]
                  end.each do |subindices|
                    document.add_element("NetworkLink").tap(&network_link(pyramid[zoom + 1][subindices], "../../#{[ zoom+1, *subindices ].join ?/}.kml"))
                  end
                end
              end
            end
            File.write tile_kml_path, xml
            
            tile_png_path = index_dir + tile_png_name
            crops = indices.map { |index| index * TILE_SIZE }
            %Q[convert "#{tif_path}" -quiet +repage -crop #{TILE_SIZE}x#{TILE_SIZE}+#{crops.join ?+} +repage +dither -type PaletteBilevelMatte PNG8:"#{tile_png_path}"]
          end
        end.flatten.tap do |commands|
          commands.each.with_index do |command, index|
            $stdout << "\r  creating tile #{index + 1} of #{commands.length}"
            %x[#{command}]
          end
          puts
        end
        
        xml = REXML::Document.new
        xml << REXML::XMLDecl.new(1.0, "UTF-8")
        xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1").tap do |kml|
          kml.add_element("Document").tap do |document|
            document.add_element("LookAt").tap do |look_at|
              range_x = map.extents.first / 2.0 / Math::tan(FOV) / Math::cos(TILT)
              range_y = map.extents.last / Math::cos(FOV - TILT) / 2 / (Math::tan(FOV - TILT) + Math::sin(TILT))
              names_values = [ %w[longitude latitude], map.projection.reproject_to_wgs84(map.centre) ].transpose
              names_values << [ "tilt", TILT * 180.0 / Math::PI ] << [ "range", 1.2 * [ range_x, range_y ].max ] << [ "heading", -map.rotation ]
              names_values.each { |name, value| look_at.add_element(name).text = value }
            end
            document.add_element("Name").text = map.name
            document.add_element("Style").tap(&style)
            document.add_element("NetworkLink").tap(&network_link(pyramid[0][[0,0]], "0/0/0.kml"))
          end
        end
        kml_path = kmz_dir + "doc.kml"
        File.write kml_path, xml
        
        temp_kmz_path = temp_dir + "#{map.name}.kmz"
        Dir.chdir(kmz_dir) { %x[#{ZIP} -r "#{temp_kmz_path}" *] }
        FileUtils.cp temp_kmz_path, kmz_path
      end
    end
  end
end

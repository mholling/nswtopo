module NSWTopo
  module Formats
    module Kmz
      TILE_SIZE = 512
      EARTH_RADIUS = 6378137.0
      TILT = 0 # 40 * Math::PI / 180.0
      FOV = 25 * Math::PI / 180.0
      extend self

      def style
        lambda do |style|
          style.add_element("ListStyle", "id" => "hideChildren").tap do |list_style|
            list_style.add_element("listItemType").text = "checkHideChildren"
          end
        end
      end

      def lat_lon_box(bounds)
        lambda do |box|
          [%w[west east south north], bounds.flatten].transpose.each do |limit, value|
            box.add_element(limit).text = value
          end
        end
      end

      def region(bounds, topmost = false)
        lambda do |region|
          region.add_element("Lod").tap do |lod|
            lod.add_element("minLodPixels").text = topmost ? 0 : TILE_SIZE / 2
            lod.add_element("maxLodPixels").text = -1
          end
          region.add_element("LatLonAltBox").tap(&lat_lon_box(bounds))
        end
      end

      def network_link(bounds, path)
        lambda do |network|
          network.add_element("Region").tap(&region(bounds))
          network.add_element("Link").tap do |link|
            link.add_element("href").text = path
            link.add_element("viewRefreshMode").text = "onRegion"
            link.add_element("viewFormat")
          end
        end
      end
    end

    def render_kmz(kmz_path, name:, ppi: PPI, **options)
      metre_resolution = 0.0254 * @scale / ppi
      degree_resolution = 180.0 * metre_resolution / Math::PI / Kmz::EARTH_RADIUS

      wgs84_bounds = @cutline.reproject_to_wgs84.bounds
      wgs84_dimensions = wgs84_bounds.map do |min, max|
        (max - min) / degree_resolution
      end

      max_zoom = Math::log2(wgs84_dimensions.max).ceil - Math::log2(Kmz::TILE_SIZE).to_i
      png_path = yield(ppi: ppi)

      Dir.mktmppath do |temp_dir|
        pyramid = (0..max_zoom).map do |zoom|
          resolution = degree_resolution * 2**(max_zoom - zoom)
          degrees_per_tile = resolution * Kmz::TILE_SIZE

          tif_path = temp_dir / "#{name}.kmz.zoom.#{zoom}.tif"
          OS.gdalwarp "-t_srs", "EPSG:4326", "-tr", resolution, resolution, "-r", "bilinear", "-dstalpha", png_path, tif_path

          corners = JSON.parse(OS.gdalinfo "-json", tif_path)["cornerCoordinates"]
          top_left = corners["upperLeft"]
          counts = corners.values.transpose.map(&:minmax).map do |min, max|
            (max - min) / degrees_per_tile
          end.map(&:ceil)

          indices_bounds = [top_left, counts, %i[+ -]].transpose.map do |coord, count, increment|
            boundaries = (0..count).map { |index| coord.send increment, index * degrees_per_tile }
            [boundaries[0..-2], boundaries[1..-1]].transpose.map(&:sort)
          end.map do |tile_bounds|
            tile_bounds.each.with_index.entries
          end.inject(:product).map(&:transpose).map(&:reverse).to_h

          log_update "kmz: resizing image pyramid: %i%%" % (100 * (2**(zoom + 1) - 1) / (2**(max_zoom + 1) - 1))
          { zoom => [indices_bounds, tif_path] }
        end.inject({}, &:merge)

        kmz_dir = temp_dir.join("#{name}.kmz").tap(&:mkpath)
        pyramid.flat_map do |zoom, (indices_bounds, tif_path)|
          zoom_dir = kmz_dir.join(zoom.to_s).tap(&:mkpath)
          indices_bounds.map do |indices, tile_bounds|
            index_dir = zoom_dir.join(indices.first.to_s).tap(&:mkpath)
            tile_kml_path = index_dir / "#{indices.last}.kml"
            tile_png_path = index_dir / "#{indices.last}.png"

            xml = REXML::Document.new
            xml << REXML::XMLDecl.new(1.0, "UTF-8")
            xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1").tap do |kml|
              kml.add_element("Document").tap do |document|
                document.add_element("Style").tap(&Kmz.style)
                document.add_element("Region").tap(&Kmz.region(tile_bounds, true))
                document.add_element("GroundOverlay").tap do |overlay|
                  overlay.add_element("drawOrder").text = zoom
                  overlay.add_element("Icon").add_element("href").text = tile_png_path.basename
                  overlay.add_element("LatLonBox").tap(&Kmz.lat_lon_box(tile_bounds))
                end
                if zoom < max_zoom
                  indices.map do |index|
                    [2 * index, 2 * index + 1]
                  end.inject(:product).select do |subindices|
                    pyramid[zoom + 1][0][subindices]
                  end.each do |subindices|
                    path = "../../%i/%i/%i.kml" % [zoom + 1, *subindices]
                    document.add_element("NetworkLink").tap(&Kmz.network_link(pyramid[zoom + 1][0][subindices], path))
                  end
                end
              end
            end
            tile_kml_path.write xml

            ["-srcwin", indices[0] * Kmz::TILE_SIZE, indices[1] * Kmz::TILE_SIZE, Kmz::TILE_SIZE, Kmz::TILE_SIZE, tif_path, tile_png_path]
          end
        end.tap do |tiles|
          log_update "kmz: creating %i tiles" % tiles.length
        end.each.concurrently do |args|
          OS.gdal_translate "--config", "GDAL_PAM_ENABLED", "NO", *args
        end.map(&:last).each.concurrent_groups do |tile_png_paths|
          dither *tile_png_paths
        rescue Dither::Missing
        end

        xml = REXML::Document.new
        xml << REXML::XMLDecl.new(1.0, "UTF-8")
        xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1").tap do |kml|
          kml.add_element("Document").tap do |document|
            document.add_element("LookAt").tap do |look_at|
              extents = @dimensions.times(@scale / 1000.0)
              range_x = extents.first / 2.0 / Math::tan(Kmz::FOV) / Math::cos(Kmz::TILT)
              range_y = extents.last / Math::cos(Kmz::FOV - Kmz::TILT) / 2 / (Math::tan(Kmz::FOV - Kmz::TILT) + Math::sin(Kmz::TILT))
              names_values = [%w[longitude latitude], @centre].transpose
              names_values << ["tilt", Kmz::TILT * 180.0 / Math::PI] << ["range", 1.2 * [range_x, range_y].max] << ["heading", rotation]
              names_values.each { |name, value| look_at.add_element(name).text = value }
            end
            document.add_element("Name").text = name
            document.add_element("Style").tap(&Kmz.style)
            document.add_element("NetworkLink").tap(&Kmz.network_link(pyramid[0][0][[0,0]], "0/0/0.kml"))
          end
        end
        kml_path = kmz_dir / "doc.kml"
        kml_path.write xml

        zip kmz_dir, kmz_path
      end
    end
  end
end

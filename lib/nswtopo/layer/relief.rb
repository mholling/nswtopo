module NSWTopo
  module Relief
    include Raster, ArcGISServer, DEM, Log
    CREATE = %w[altitude azimuth factor sources highlights radius median bilateral contours]
    DEFAULTS = YAML.load <<~YAML
      altitude: 45
      azimuth: 315
      factor: 2.5
      sources: 3
      highlights: 20
      radius: 4
      resolution: 30.0
      opacity: 0.3
    YAML

    def margin
      { mm: 3 * @radius }
    end

    def get_raster(temp_dir)
      dem_path = temp_dir / "dem.tif"

      case
      when @path
        get_dem temp_dir, dem_path

      when @contours
        bounds = @map.bounds(margin: margin)
        txe, tye, spat = bounds[0], bounds[1].reverse, bounds.transpose.flatten
        outsize = (bounds.transpose.difference / @resolution).map(&:ceil)

        collection = @contours.map do |url_or_path, attribute|
          raise "no elevation attribute specified for #{url_or_path}" unless attribute
          case url_or_path
          when ArcGISServer
            arcgis_layer url_or_path, margin: margin do |index, total|
              log_update "%s: retrieved %i of %i contours" % [@name, index, total]
            end.each do |feature|
              feature.properties.replace "elevation" => feature.fetch(attribute, attribute).to_f
            end
          # when Shapefile
            # TODO: add contour importing from shapefile path + layer name
          else
            raise "unrecognised elevation data source: #{url_or_path}"
          end.reproject_to(@map.projection)
        end.inject(&:merge)

        log_update "%s: calculating DEM" % @name
        OS.gdal_grid "-a", "linear:radius=0:nodata=-9999", "-zfield", "elevation", "-ot", "Float32", "-txe", *txe, "-tye", *tye, "-spat", *spat, "-outsize", *outsize, "/vsistdin/", dem_path do |stdin|
          stdin.puts collection.to_json
        end

      else
        raise "no elevation data specified for relief layer #{@name}"
      end

      log_update "%s: calculating relief shading" % @name
      reliefs = -90.step(90, 90.0 / @sources).select.with_index do |offset, index|
        index.odd?
      end.map do |offset|
        (@azimuth + offset) % 360
      end.map do |azimuth|
        relief_path = temp_dir / "relief.#{azimuth}.bil"
        OS.gdaldem "hillshade", "-of", "EHdr", "-compute_edges", "-s", 1, "-alt", @altitude, "-z", @factor, "-az", azimuth, dem_path, relief_path
        [azimuth, ESRIHdr.new(relief_path, 0)]
      rescue OS::Error
        raise "invalid elevation data"
      end.to_h

      bil_path = temp_dir / "relief.bil"
      if reliefs.one?
        reliefs.values.first.write bil_path
      else
        blur_path = temp_dir / "dem.blurred.tif"
        blur_dem dem_path, blur_path

        aspect_path = temp_dir / "aspect.bil"
        OS.gdaldem "aspect", "-zero_for_flat", "-of", "EHdr", blur_path, aspect_path
        aspect = ESRIHdr.new aspect_path, 0.0

        reliefs.map do |azimuth, relief|
          [relief.values, aspect.values].transpose.map do |relief, aspect|
            relief ? aspect ? 2 * relief * Math::sin((aspect - azimuth) * Math::PI / 180)**2 : relief : 0
          end
        end.transpose.map do |values|
          values.inject(&:+) / @sources
        end.map do |value|
          [255, value.ceil].min
        end.tap do |values|
          ESRIHdr.new(reliefs.values.first, values).write bil_path
        end
      end

      tif_path = temp_dir / "relief.tif"
      OS.gdalwarp "-co", "TFW=YES", "-s_srs", @map.projection, "-srcnodata", 0, "-dstalpha", bil_path, tif_path

      filters = []
      if @median
        pixels = (2 * @median + 1).to_i
        filters += %W[-channel RGBA -statistic median #{pixels}x#{pixels}]
      end
      if @bilateral
        threshold, sigma = *@bilateral, (60.0 / @resolution).round
        filters += %W[-channel RGB -selective-blur 0x#{sigma}+#{threshold}%]
      end
      OS.mogrify "-virtual-pixel", "edge", *filters, tif_path if filters.any?

      threshold = Math::sin(@altitude * Math::PI / 180)
      shade = %W[-colorspace Gray -fill white -opaque none -level #{   90*threshold}%,0%                             -alpha Copy -fill black  +opaque black ]
      sun   = %W[-colorspace Gray -fill black -opaque none -level #{10+90*threshold}%,100% +level 0%,#{@highlights}% -alpha Copy -fill yellow +opaque yellow]

      temp_dir.join("composite.tif").tap do |composite_path|
        OS.convert "-quiet", ?(, tif_path, *shade, ?), ?(, tif_path, *sun, ?), "-composite", composite_path
        FileUtils.mv composite_path, tif_path
      end

      return @resolution, tif_path
    end
  end
end

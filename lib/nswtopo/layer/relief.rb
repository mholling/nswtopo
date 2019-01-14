module NSWTopo
  module Relief
    include Raster, ArcGISServer, Log
    CREATE = %w[altitude azimuth exaggeration lightsources highlights sigma median bilateral contours]
    DEFAULTS = YAML.load <<~YAML
      altitude: 45
      azimuth: 315
      exaggeration: 2.5
      lightsources: 3
      highlights: 20
      sigma: 100
      median: 3
      bilateral: 4
      resolution: 30.0
      opacity: 0.3
    YAML

    def get_raster(temp_dir)
      dem_path = temp_dir / "dem.tif"
      margin = { metres: 3 * @sigma }

      bounds = @map.bounds(margin: margin)
      txe, tye, spat = bounds[0], bounds[1].reverse, bounds.transpose.flatten
      outsize = (bounds.transpose.difference / @resolution).map(&:ceil)

      case
      when @path
        txt_path = temp_dir / "dem.txt"
        vrt_path = temp_dir / "dem.vrt"

        # TODO: handle multiple projections, as per Vegetation layer?
        raise "no elevation data found at specified path" if @paths.none?
        txt_path.write @paths.join(?\n)
        OS.gdalbuildvrt "-input_file_list", txt_path, vrt_path
        OS.gdalwarp "-t_srs", @map.projection, "-te", *bounds.transpose.flatten, "-tr", @resolution, @resolution, "-r", "bilinear", vrt_path, dem_path

      when @contours
        collection = @contours.map do |url_or_path, attribute|
          raise "no elevation attribute specified for #{url_or_path}" unless attribute
          case url_or_path
          when ArcGISServer
            arcgis_layer url_or_path, margin: margin do |index, total|
              log_update "%s: retrieved %i of %i contours" % [@name, index, total]
            end.each do |feature|
              feature.properties.replace "elevation" => feature.properties.fetch(attribute, attribute).to_f
            end
          # when Shapefile
            # TODO: add contour importing from shapefile path + layer name
          else
            raise "unrecognised elevation data source: #{url_or_path}"
          end.reproject_to(@map.projection)
        end.inject(&:merge)

        OS.gdal_grid "-a", "linear:radius=0:nodata=-9999", "-zfield", "elevation", "-ot", "Float32", "-txe", *txe, "-tye", *tye, "-spat", *spat, "-outsize", *outsize, "/vsistdin/", dem_path do |stdin|
          stdin.puts collection.to_json
        end

      else
        raise "no elevation data specified for relief layer #{@name}"
      end

      reliefs = -90.step(90, 90.0 / @lightsources).select.with_index do |offset, index|
        index.odd?
      end.map do |offset|
        (@azimuth + offset) % 360
      end.map do |azimuth|
        relief_path = temp_dir / "relief.#{azimuth}.bil"
        OS.gdaldem "hillshade", "-of", "EHdr", "-compute_edges", "-s", 1, "-alt", @altitude, "-z", @exaggeration, "-az", azimuth, dem_path, relief_path
        [azimuth, ESRIHdr.new(relief_path, 0)]
      rescue OS::Error
        raise "invalid elevation data"
      end.to_h

      bil_path = temp_dir / "relief.bil"
      if reliefs.one?
        reliefs.values.first.write bil_path
      else
        json = OS.gdalinfo "-json", dem_path
        nodata = JSON.parse(json).dig("bands", 0, "noDataValue")
        blur_path = temp_dir / "dem.blurred.bil"
        OS.gdal_translate "-of", "EHdr", dem_path, blur_path
        dem = ESRIHdr.new blur_path, nodata

        # TODO: should sigma be in pixels instead of metres?
        (@sigma.to_f / @resolution).ceil.times.inject(dem.rows) do |rows|
          2.times.inject(rows) do |rows|
            rows.map do |row|
              row.map do |value|
                value && value.nan? ? nil : value
              end.each_cons(3).map do |window|
                window[1] && window.compact.inject(&:+) / window.compact.length
              end.push(nil).unshift(nil)
            end.transpose
          end
        end.flatten.tap do |blurred|
          ESRIHdr.new(dem, blurred).write blur_path
        end

        aspect_path = temp_dir / "aspect.bil"
        OS.gdaldem "aspect", "-zero_for_flat", "-of", "EHdr", blur_path, aspect_path
        aspect = ESRIHdr.new aspect_path, 0.0

        reliefs.map do |azimuth, relief|
          [relief.values, aspect.values].transpose.map do |relief, aspect|
            relief ? aspect ? 2 * relief * Math::sin((aspect - azimuth) * Math::PI / 180)**2 : relief : 0
          end
        end.transpose.map do |values|
          values.inject(&:+) / @lightsources
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

module NSWTopo
  module Relief
    include Raster, ArcGISServer, Shapefile, DEM, Log
    CREATE = %w[altitude azimuth factor sources yellow smooth median bilateral contours]
    DEFAULTS = YAML.load <<~YAML
      altitude: 45
      azimuth: 315
      factor: 2.0
      sources: 3
      yellow: 0.2
      smooth: 4
      resolution: 5.0
      opacity: 0.3
    YAML

    def margin
      { mm: 3 * @smooth }
    end

    def get_raster(temp_dir)
      dem_path = temp_dir / "dem.tif"
      flat_relief = (Math::sin(@altitude * Math::PI / 180) * 255).to_i

      case
      when @path
        get_dem temp_dir, dem_path

      when @contours
        bounds = @map.bounds(margin: margin)
        txe, tye, spat = bounds[0], bounds[1].reverse, bounds.transpose.flatten
        outsize = (bounds.transpose.difference / @resolution).map(&:ceil)

        collection = @contours.map do |url_or_path, attribute_or_hash|
          raise "no elevation attribute specified for #{url_or_path}" unless attribute_or_hash
          options   = Hash == attribute_or_hash ? attribute_or_hash.transform_keys(&:to_sym).slice(:where, :layer) : {}
          attribute = Hash == attribute_or_hash ? attribute_or_hash["attribute"] : attribute_or_hash
          case url_or_path
          when ArcGISServer
            arcgis_layer url_or_path, margin: margin, **options do |index, total|
              log_update "%s: retrieved %i of %i contours" % [@name, index, total]
            end
          when Shapefile
            shapefile_layer source_path, margin: margin, **options
          else
            raise "unrecognised elevation data source: #{url_or_path}"
          end.each do |feature|
            feature.properties.replace "elevation" => feature.fetch(attribute, attribute).to_f
          end.reproject_to(@map.projection)
        end.inject(&:merge)

        log_update "%s: calculating DEM" % @name
        OS.gdal_grid "-a", "linear:radius=0:nodata=-9999", "-zfield", "elevation", "-ot", "Float32", "-txe", *txe, "-tye", *tye, "-spat", *spat, "-outsize", *outsize, "/vsistdin/", dem_path do |stdin|
          stdin.puts collection.to_json
        end

      else
        raise "no elevation data specified for relief layer #{@name}"
      end

      log_update "%s: generating shaded relief" % @name
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

        log_update "%s: combining shaded relief" % @name
        reliefs.map do |azimuth, relief|
          [relief.values, aspect.values].transpose.map do |relief, aspect|
            relief ? aspect ? 2 * relief * Math::sin((aspect - azimuth) * Math::PI / 180)**2 : relief : flat_relief
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
      OS.gdalwarp "-co", "TFW=YES", "-s_srs", @map.projection, "-dstnodata", "None", bil_path, tif_path

      filters = []
      if @median
        pixels = (2 * @median + 1).to_i
        filters += %W[-channel RGBA -statistic median #{pixels}x#{pixels}]
      end
      if @bilateral
        threshold, sigma = *@bilateral, (60.0 / @resolution).round
        filters += %W[-channel RGB -selective-blur 0x#{sigma}+#{threshold}%]
      end
      if filters.any?
        log_update "%s: applying filters" % @name
        OS.mogrify "-virtual-pixel", "edge", *filters, tif_path
      end

      log_update "%s: rendering shaded relief" % @name
      vrt_path = temp_dir / "coloured.vrt"
      OS.gdalbuildvrt vrt_path, tif_path

      xml = REXML::Document.new vrt_path.read
      vrt_raster_band = xml.elements["VRTDataset/VRTRasterBand[ColorInterp[text()='Gray']]"]
      vrt_raster_band.elements["ColorInterp[text()='Gray']"].text = "Palette"
      color_table = vrt_raster_band.add_element "ColorTable"

      shade, sun = 90 * flat_relief / 100, (10 + 90 * flat_relief) / 100
      256.times do |index|
        case
        when index < shade
          color_table.add_element "Entry", "c1" => 0, "c2" => 0, "c3" => 0, "c4" => (shade - index) * 255 / shade
        when index > sun
          color_table.add_element "Entry", "c1" => 255, "c2" => 255, "c3" => 0, "c4" => ((index - sun) * 255 * @yellow / (255 - sun)).to_i
        else
          color_table.add_element "Entry", "c1" => 0, "c2" => 0, "c3" => 0, "c4" => 0
        end
      end

      vrt_path.write xml
      coloured_path = temp_dir / "coloured.tif"
      OS.gdal_translate "-expand", "rgba", vrt_path, coloured_path
      FileUtils.mv coloured_path, tif_path
      return @resolution, tif_path
    end
  end
end

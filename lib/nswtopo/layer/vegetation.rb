module NSWTopo
  module Vegetation
    include Raster, MaskRender, GDALGlob
    CREATE = %w[mapping contrast]
    DEFAULTS = YAML.load <<~YAML
      colour: hsl(75,55%,72%)
    YAML

    def get_raster(temp_dir)
      @params["colour"] = @params["colour"]["woody"] if Hash === @params["colour"]
      min, max = minmax = @mapping&.values_at("min", "max")
      low, high, factor = [0, 100, 0].zip(Array @contrast&.values_at("low", "high", "factor")).map(&:compact).map(&:last)

      alpha_table = (0..255).map do |index|
        case
        when minmax&.all?(Integer) && minmax.all?(0..255)
          (100.0 * (index - min) / (max - min)).clamp(0.0, 100.0)
        when @mapping&.keys&.all?(Integer)
          @mapping.fetch(index, 0)
        else raise "no vegetation colour mapping specified for #{name}"
        end
      end.map do |percent|
        (Float(percent - low) / (high - low)).clamp(0.0, 1.0)
      end.map do |x|
        next x if factor.zero?
        [x, 1.0].map do |x|
          [x, 0.0].map do |x|
            1 / (1 + Math::exp(factor * (0.5 - x)))
          end.inject(&:-)
        end.inject(&:/) # sigmoid between 0..1
      end.map do |x|
        Integer(255 * x)
      end

      Dir.chdir(@source ? @source.parent : Pathname.pwd) do
        gdal_rasters @path
      end.each do |path, info|
        raise "can't process vegetation data for #{@name}" unless info["bands"].one?
        raise "can't process vegetation data for #{@name}" unless info.dig("bands", 0, "colorInterpretation") == "Palette"
        raise "can't process vegetation data for #{@name}" unless info.dig("bands", 0, "colorTable", "count") == 256
      end.group_by do |path, info|
        info.dig("bands", 0).values_at("colorTable", "noDataValue")
      end.values.then do |rasters, *others|
        raise "no vegetation data file specified" unless rasters
        raise "can't process vegetation data for #{@name}" if others.any?
        rasters
      end.group_by do |path, info|
        Projection.new info.dig("coordinateSystem", "wkt")
      end.map.with_index do |(projection, rasters), index|
        vrt_path = temp_dir / "indexed.#{index}.vrt"
        txt_path = temp_dir / "source.txt"

        txt_path.write rasters.map(&:first).join(?\n)
        OS.gdalbuildvrt "-overwrite", "-r", "nearest", "-input_file_list", txt_path, vrt_path

        xml = REXML::Document.new vrt_path.read
        xml.elements.collect("/VRTDataset/VRTRasterBand/ColorTable/Entry", &:itself).zip(alpha_table) do |entry, alpha|
          entry.attributes["c1"], entry.attributes["c2"], entry.attributes["c3"], entry.attributes["c4"] = alpha, alpha, alpha, 255
        end

        vrt_path.write xml
        vrt_path
      end.then do |vrt_paths|
        tif_path = temp_dir / "source.tif"
        vrt_path = temp_dir / "source.vrt"

        args = ["-t_srs", @map.projection, "-r", "nearest", "-cutline", "GeoJSON:/vsistdin?buffer_limit=-1", "-crop_to_cutline"]
        args += ["-tr", @mm_per_px, @mm_per_px] if @mm_per_px
        OS.gdalwarp *args, *vrt_paths, tif_path do |stdin|
          stdin.puts @map.cutline.to_json
        end
        OS.gdal_translate "-expand", "gray", "-a_nodata", "none", tif_path, vrt_path

        return vrt_path
      end
    end
  end
end

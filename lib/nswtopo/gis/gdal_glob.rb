module NSWTopo
  module GDALGlob
    def gdal_raster?(format)
      @gdal_formats ||= OS.gdalinfo("--formats").each_line.drop(1).map do |line|
        line.strip.split(?\s).first
      end - %w[PDF]
      @gdal_formats.include? format
    end

    def gdal_rasters(path)
      paths = Array(path).flat_map do |path|
        Pathname.glob Pathname(path).expand_path
      end

      total = nil
      Enumerator.new do |yielder|
        while path = paths.pop
          OS.gdalmanage("identify", "-r", "-u", path).each_line.map do |line|
            line.chomp.split ": "
          end.each do |component, format|
            case
            when gdal_raster?(format) then yielder << component
            when path == component 
            when component !~ /\.zip$/
            else paths << "/vsizip/#{component}"
            end
          end
        end
      end.entries.tap do |paths|
        total = paths.length
      end.map.with_index do |path, index|
        yield [index + 1, total] if block_given?
        info = JSON.parse OS.gdalinfo("-json", path)
        next unless info["geoTransform"]
        next unless wkt = info.dig("coordinateSystem", "wkt")
        next path, info
      rescue JSON::ParserError
      end.compact
    end
  end
end

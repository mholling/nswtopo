module NSWTopo
  module GDALGlob
    extend self

    def raster?(format)
      @formats ||= OS.gdalinfo("--formats").each_line.drop(1).map do |line|
        line.strip.split(?\s).first
      end
      @formats.include? format
    end

    def rasters(path)
      paths = Array(path).flat_map do |path|
        Pathname.glob Pathname(path).expand_path
      end
      Enumerator.new do |yielder|
        while path = paths.pop
          OS.gdalmanage("identify", "-r", "-u", path).each_line.map do |line|
            line.chomp.split ": "
          end.each do |component, format|
            case
            when raster?(format) then yielder << component
            when path == component 
            when component !~ /\.zip$/
            else paths << "/vsizip/#{component}"
            end
          end
        end
      end.map do |path|
        info = JSON.parse OS.gdalinfo("-json", path)
        next unless info["geoTransform"]
        next unless wkt = info.dig("coordinateSystem", "wkt")
        next path, info
      rescue JSON::ParserError
      end.compact
    end
  end
end

module NSWTopo
  module Raster
    def create
      Dir.mktmppath do |temp_dir|
        out_path = temp_dir / "output.tif"

        args = ["-t_srs", @map.projection, "-r", "bilinear", "-cutline", "GeoJSON:/vsistdin/", "-crop_to_cutline"]
        args += ["-tr", @resolution, @resolution] if Numeric === @resolution
        OS.gdalwarp *args, get_raster(temp_dir), out_path do |stdin|
          stdin.puts @map.cutline.to_json
        end

        @map.write filename, out_path.binread
      end
    end

    def filename
      "#{@name}.tif"
    end

    def empty?
      false
    end

    def size_resolution
      OS.gdalinfo "-json", "/vsistdin/" do |stdin|
        stdin.binmode.write @map.read(filename)
      end.then do |json|
        JSON.parse(json).values_at "size", "geoTransform"
      end.then do |size, geotransform|
        next size, geotransform[1]
      end
    end

    def to_s
      size, resolution = size_resolution
      megapixels = size.inject(&:*) / 1024.0 / 1024.0
      ppi = 0.0254 * @map.scale / resolution
      "%s: %i×%i (%.1fMpx) @ %.2fm/px (%.0f ppi)" % [@name, *size, megapixels, resolution, ppi]
    end
  end
end

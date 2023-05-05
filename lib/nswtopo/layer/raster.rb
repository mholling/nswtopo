module NSWTopo
  module Raster
    def create
      Dir.mktmppath do |temp_dir|
        out_path = temp_dir / "output.tif"

        args = ["-t_srs", @map.projection, "-r", "bilinear", "-cutline", "GeoJSON:/vsistdin/", "-crop_to_cutline"]
        args += ["-tr", @mm_per_px, @mm_per_px] if Numeric === @mm_per_px
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

    def image_element
      REXML::Element.new("image").tap do |image|
        tif = @map.read filename
        OS.gdalinfo "-json", "/vsistdin/" do |stdin|
          stdin.binmode.write tif
        end.then do |json|
          JSON.parse(json).values_at "size", "geoTransform"
        end.then do |(width, height), (_, mm_per_px, *)|
          image.add_attributes "width" => width, "height" => height, "transform" => "scale(#{mm_per_px})"
        end
        OS.gdal_translate "-of", "PNG", "-co", "ZLEVEL=9", "/vsistdin/", "/vsistdout/" do |stdin|
          stdin.binmode.write tif
        end.then do |png|
          image.add_attributes "href" => "data:image/png;base64,#{Base64.encode64 png}", "image-rendering" => "optimizeQuality"
        end
      end
    end

    def to_s
      OS.gdalinfo "-json", "/vsistdin/" do |stdin|
        stdin.binmode.write @map.read(filename)
      end.then do |json|
        JSON.parse(json).values_at "size", "geoTransform"
      end.then do |(width, height), (_, mm_per_px, *)|
        resolution, ppi = @map.to_metres(mm_per_px), 25.4 / mm_per_px
        megapixels = width * height / 1024.0 / 1024.0
        "%s: %i×%i (%.1fMpx) @ %.1fm/px (%.0f ppi)" % [@name, width, height, megapixels, resolution, ppi]
      end
    end
  end
end

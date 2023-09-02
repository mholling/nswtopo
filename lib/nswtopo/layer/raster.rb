module NSWTopo
  module Raster
    using Helpers
    def create
      Dir.mktmppath do |temp_dir|
        args = ["-t_srs", @map.projection, "-r", "bilinear", "-cutline", "GeoJSON:/vsistdin/", "-te", *@map.te, "-of", "GTiff", "-co", "TILED=YES"]
        args += ["-tr", @mm_per_px, @mm_per_px] if Numeric === @mm_per_px
        OS.gdalwarp *args, get_raster(temp_dir), "/vsistdout/" do |stdin|
          stdin.puts @map.cutline.to_json
        end.then do |tif|
          @map.write filename, tif
        end
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
        "%s: %i×%i (%.1fMpx) @ %.3gm/px (%.3g ppi)" % [@name, width, height, megapixels, resolution, ppi]
      end
    end
  end
end

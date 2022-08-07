module NSWTopo
  module Raster
    def create
      tif = Dir.mktmppath do |temp_dir|
        tif_path = temp_dir / "final.tif"
        out_path = temp_dir / "output.tif"

        resolution, raster_path = get_raster(temp_dir)
        tr, te = [resolution, resolution], @map.bounds.transpose.flatten
        OS.gdalwarp "-t_srs", @map.projection, "-tr", *tr, "-te", *te, "-r", "bilinear", raster_path, tif_path

        density = 0.01 * @map.scale / resolution
        tiff_tags = %W[-mo TIFFTAG_XRESOLUTION=#{density} -mo TIFFTAG_YRESOLUTION=#{density} -mo TIFFTAG_RESOLUTIONUNIT=3]

        OS.gdal_translate *tiff_tags, tif_path, out_path
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
      "%s: %i×%i (%.1fMpx) @ %.1fm/px (%.0f ppi)" % [@name, *size, megapixels, resolution, ppi]
    end

    def render(group, masks:, **)
      masks.each.with_object group.add_element("defs").add_element("mask", "id" => "#{name}.mask").add_element("g", "filter" => "url(#map.filter.cutout)") do |id, mask_content|
        mask_content.add_element "use", "href" => "##{id}"
      end if masks.any?
      OS.gdal_translate("-of", "PNG", "-co", "ZLEVEL=9", "/vsistdin/", "/vsistdout/") do |stdin|
        stdin.binmode.write @map.read(filename)
      end.tap do |png|
        (width, height), resolution = size_resolution
        transform = "scale(#{resolution / @map.metres_per_mm})"
        href = "data:image/png;base64,#{Base64.encode64 png}"
        image = group.add_element "image", "transform" => transform, "width" => width, "height" => height, "image-rendering" => "optimizeQuality", "href" => href
        image.add_attributes "mask" => "url(##{name}.mask)" if masks.any?
        image.add_attributes params.slice("opacity")
      end
    end
  end
end

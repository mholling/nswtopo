module NSWTopo
  module Raster
    def create
      tif = Dir.mktmppath do |temp_dir|
        tif_path = temp_dir / "final.tif"
        out_path = temp_dir / "output.tif"

        resolution, raster_path = get_raster(temp_dir)
        @map.write_empty_raster tif_path, resolution: resolution
        OS.gdalwarp "-r", "bilinear", raster_path, tif_path

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
      json = OS.gdalinfo "-json", "/vsistdin/" do |stdin|
        stdin.binmode
        stdin.write @map.read(filename)
      end
      size, geotransform = JSON.parse(json).values_at "size", "geoTransform"
      resolution = geotransform.values_at(1, 2).norm
      return size, resolution
    end

    def to_s
      size, resolution = size_resolution
      megapixels = size.inject(&:*) / 1024.0 / 1024.0
      ppi = 0.0254 * @map.scale / resolution
      "%s: %i×%i (%.1fMpx) @ %.1fm/px (%.0f ppi)" % [@name, *size, megapixels, resolution, ppi]
    end

    def render(group, masks:, **)
      (width, height), resolution = size_resolution
      group.add_element("defs").add_element("mask", "id" => "#{name}.mask").add_element("g", "filter" => "url(#map.filter.alpha2mask)").tap do |mask_content|
        masks.each do |id|
          mask_content.add_element "use", "href" => "##{id}"
        end
        group.add_attribute "mask", "url(##{name}.mask)"
      end if masks.any?
      transform = "scale(#{1000.0 * resolution / @map.scale})"
      png = Dir.mktmppath do |temp_dir|
        tif_path = temp_dir / "raster.tif"
        png_path = temp_dir / "raster.png"
        tif_path.binwrite @map.read(filename)
        OS.gdal_translate "-of", "PNG", "-co", "ZLEVEL=9", tif_path, png_path
        png_path.binread
      end
      href = "data:image/png;base64,#{Base64.encode64 png}"
      image = group.add_element "image", "transform" => transform, "width" => width, "height" => height, "image-rendering" => "optimizeQuality", "href" => href
      image.add_attributes params.slice("opacity")
    end
  end
end

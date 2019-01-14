module NSWTopo
  module Raster
    def create
      tif = Dir.mktmppath do |temp_dir|
        tif_path = temp_dir / "final.tif"
        tfw_path = temp_dir / "final.tfw"
        out_path = temp_dir / "output.tif"

        resolution, raster_path = get_raster(temp_dir)
        dimensions, ppi, resolution = @map.raster_dimensions_at resolution: resolution
        density = 0.01 * @map.scale / resolution
        tiff_tags = %W[-mo TIFFTAG_XRESOLUTION=#{density} -mo TIFFTAG_YRESOLUTION=#{density} -mo TIFFTAG_RESOLUTIONUNIT=3]

        @map.write_world_file tfw_path, resolution: resolution
        OS.convert "-size", dimensions.join(?x), "canvas:none", "-type", "TrueColorMatte", "-depth", 8, tif_path
        OS.gdalwarp "-t_srs", @map.projection, "-r", "bilinear", raster_path, tif_path
        OS.gdal_translate "-a_srs", @map.projection, *tiff_tags, tif_path, out_path
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

    def render(group, defs)
      (width, height), resolution = size_resolution
      group.add_attributes "style" => "opacity:%s" % params.fetch("opacity", 1)
      transform = "scale(#{1000.0 * resolution / @map.scale})"
      png = Dir.mktmppath do |temp_dir|
        tif_path = temp_dir / "raster.tif"
        png_path = temp_dir / "raster.png"
        tif_path.binwrite @map.read(filename)
        OS.gdal_translate "-of", "PNG", "-co", "ZLEVEL=9", tif_path, png_path
        png_path.binread
      end
      href = "data:image/png;base64,#{Base64.encode64 png}"
      group.add_element "image", "transform" => transform, "width" => width, "height" => height, "image-rendering" => "optimizeQuality", "xlink:href" => href
      group.add_attribute "mask", "url(#raster-mask)" if defs.elements["mask[@id='raster-mask']"]
    end
  end
end

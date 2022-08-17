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
      "%s: %i×%i (%.1fMpx) @ %.2fm/px (%.0f ppi)" % [@name, *size, megapixels, resolution, ppi]
    end
  end
end

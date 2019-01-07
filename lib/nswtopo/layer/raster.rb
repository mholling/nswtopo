module NSWTopo
  module Raster
    def create
      tif = Dir.mktmppath do |temp_dir|
        tif_path = temp_dir / "final.tif"
        tfw_path = temp_dir / "final.tfw"
        out_path = temp_dir / "output.tif"

        resolution, raster_path = get_raster(temp_dir)
        dimensions = (@map.extents / resolution).map(&:ceil)
        density = 0.01 * @map.scale / resolution
        tiff_tags = %W[-mo TIFFTAG_XRESOLUTION=#{density} -mo TIFFTAG_YRESOLUTION=#{density} -mo TIFFTAG_RESOLUTIONUNIT=3]

        @map.write_world_file tfw_path, resolution: resolution
        OS.convert "-size", dimensions.join(?x), "canvas:none", "-type", "TrueColorMatte", "-depth", 8, tif_path
        OS.gdalwarp "-t_srs", @map.projection, "-r", "bilinear", raster_path, tif_path
        OS.gdal_translate "-a_srs", @map.projection, *tiff_tags, tif_path, out_path
        @map.write filename, out_path.read
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
        stdin.write @map.read(filename)
      rescue Errno::EPIPE # gdalinfo only reads the TIFF header
      end
      size, geotransform = JSON.parse(json).values_at "size", "geoTransform"
      resolution = geotransform.values_at(1, 2).norm
      return size, resolution
    end

    def to_s
      size, resolution = size_resolution
      megapixels = size.inject(&:*) / 1024.0 / 1024.0
      ppi = 0.0254 * @map.scale / resolution
      "%s: %i×%i (%.1fMpx) @ %.1fm/px (%.0f ppi)" % [ @name, *size, megapixels, resolution, ppi ]
    end

    # TODO: can following two methods be refactored/removed to use #size_resolution instead?
    def get_resolution(path)
      OS.gdaltransform path, '-t_srs', @map.projection do |stdin|
        stdin.puts "0 0", "1 1"
      end.each_line.map do |line|
        line.split(?\s).take(2).map(&:to_f)
      end.distance.* Math.sqrt(0.5)
    rescue OS::Error
      raise "invalid raster"
    end

    def render(group, defs)
      (width, height), resolution = size_resolution
      group.add_attributes "style" => "opacity:%s" % params.fetch("opacity", 1)
      transform = "scale(#{1000.0 * resolution / @map.scale})"
      png = Dir.mktmppath do |temp_dir|
        tif_path = temp_dir / "raster.tif"
        png_path = temp_dir / "raster.png"
        tif_path.write @map.read(filename)
        OS.gdal_translate "-of", "PNG", "-co", "ZLEVEL=9", tif_path, png_path
        png_path.read
      end
      href = "data:image/png;base64,#{Base64.encode64 png}"
      if params["masks"]
        # # TODO: handle masking
        # filter_id, mask_id = "#{@name}.filter", "#{@name}.mask"
        # defs.add_element("filter", "id" => filter_id).add_element "feColorMatrix", "type" => "matrix", "in" => "SourceGraphic", "values" => "0 0 0 0 1   0 0 0 0 1   0 0 0 0 1   0 0 0 -1 1"
        # defs.add_element("mask", "id" => mask_id).add_element("g", "filter" => "url(#%s)" % filter_id).tap do |g|
        #   g.add_element "rect", "width" => "100%", "height" => "100%", "fill" => "none", "stroke" => "none"
        #   [ *params["masks"] ].each do |id|
        #     next unless element = xml.elements["//g[@id='#{id}']"]
        #     transforms = REXML::XPath.each(xml, "//g[@id='#{id}']/ancestor::g[@transform]/@transform").map(&:value)
        #     g.add_element "use", "xlink:href" => "##{id}", "transform" => (transforms.join(?\s) if transforms.any?)
        #   end
        # end
        # group.add_element "g", "mask" => "url(#%s)" % mask_id
      else
        group
      end.add_element "image", "transform" => transform, "width" => width, "height" => height, "image-rendering" => "optimizeQuality", "xlink:href" => href
    end
  end
end

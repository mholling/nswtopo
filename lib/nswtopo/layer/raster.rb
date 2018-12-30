module NSWTopo
  module Raster
    def filename
      "#{@name}.tif"
    end

    def create
      # TODO: report raster dimensions?
      tif = Dir.mktmppath do |temp_dir|
        tif_path = temp_dir / "final.tif"
        tfw_path = temp_dir / "final.tfw"

        resolution, raster_path = get_raster(temp_dir)
        dimensions = (@map.extents / resolution).map(&:ceil)
        density = 0.01 * @map.scale / resolution
        tiff_tags = %W[-mo TIFFTAG_XRESOLUTION=#{density} -mo TIFFTAG_YRESOLUTION=#{density} -mo TIFFTAG_RESOLUTIONUNIT=3]

        @map.write_world_file tfw_path, resolution
        OS.convert "-size", dimensions.join(?x), "canvas:none", "-type", "TrueColorMatte", "-depth", 8, tif_path
        OS.gdalwarp "-t_srs", @map.projection, "-r", "bilinear", raster_path, tif_path
        OS.gdal_translate "-a_srs", @map.projection, "-of", "GTiff", *tiff_tags, tif_path, "/vsistdout/"
      end

      @map.write filename, tif
    end

    def to_s
      json = OS.gdalinfo "-json", "/vsistdin/" do |stdin|
        stdin.write @map.read(filename)
      rescue Errno::EPIPE # gdalinfo only reads the TIFF header
      end
      size, geotransform = JSON.parse(json).values_at "size", "geoTransform"
      megapixels = size.inject(&:*) / 1024.0 / 1024.0
      resolution = geotransform.values_at(1, 2).norm
      ppi = 0.0254 * @map.scale / resolution
      "%s: %i×%i (%.1f Mpx) @ %.1f m/px (%.0f ppi)" % [ @name, *size, megapixels, resolution, ppi ]
    end

    def get_resolution(path)
      OS.gdaltransform path, '-t_srs', @map.projection do |stdin|
        stdin.puts "0 0", "1 1"
      end.each_line.map do |line|
        line.split(?\s).take(2).map(&:to_f)
      end.distance.* Math.sqrt(0.5)
    rescue OS::Error
      raise "invalid raster"
    end

    def get_projected_resolution(resolution, target_projection)
      OS.gdaltransform '-s_srs', @map.projection, '-t_srs', target_projection do |stdin|
        stdin.puts @map.coordinates.join(?\s), [resolution, resolution].plus(@map.coordinates).join(?\s)
      end.each_line.map do |line|
        line.split(?\s).take(2).map(&:to_f)
      end.distance.* Math.sqrt(0.5)
    rescue OS::Error
      raise "invalid projection"
    end
  end
end

# def render_svg(xml)
#   transform = "scale(#{1000.0 * resolution / CONFIG.map.scale})"
#   opacity = params["opacity"] || 1

#   raise BadLayerError.new("#{name} raster image not found at #{path}") unless path.exist?
#   href = if params["embed"]
#     base64 = Base64.encode64 path.read(:mode => "rb")
#     mimetype = %x[identify -quiet -verbose "#{path}"][/image\/\w+/] || "image/png"
#     "data:#{mimetype};base64,#{base64}"
#   else
#     path.basename
#   end

#   if layer = yield
#     if params["masks"]
#       defs = xml.elements["//svg/defs"]
#       filter_id, mask_id = "#{name}.filter", "#{name}.mask"
#       defs.elements.each("[@id='#{filter_id}' or @id='#{mask_id}']", &:remove)
#       defs.add_element("filter", "id" => filter_id).add_element "feColorMatrix", "type" => "matrix", "in" => "SourceGraphic", "values" => "0 0 0 0 1   0 0 0 0 1   0 0 0 0 1   0 0 0 -1 1"
#       defs.add_element("mask", "id" => mask_id).add_element("g", "filter" => "url(##{filter_id})").tap do |g|
#         g.add_element "rect", "width" => "100%", "height" => "100%", "fill" => "none", "stroke" => "none"
#         [ *params["masks"] ].each do |id|
#           next unless element = xml.elements["//g[@id='#{id}']"]
#           transforms = REXML::XPath.each(xml, "//g[@id='#{id}']/ancestor::g[@transform]/@transform").map(&:value)
#           g.add_element "use", "xlink:href" => "##{id}", "transform" => (transforms.join(?\s) if transforms.any?)
#         end
#       end
#       layer.add_element("g", "mask" => "url(##{mask_id})")
#     else
#       layer
#     end.add_element("image", "transform" => transform, "width" => dimensions[0], "height" => dimensions[1], "image-rendering" => "optimizeQuality", "xlink:href" => href)

#     opacity = params["opacity"] || 1
#     layer.add_attributes "style" => "opacity:#{opacity}"
#   end
# end

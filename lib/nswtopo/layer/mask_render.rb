module NSWTopo
  module MaskRender
    def render(cutouts:, **, &block)
      defs = REXML::Element.new("defs").tap(&block)
      defs.add_attributes "id" => "#{@name}.defs"

      Dir.mktmppath do |tmp|
        tmp.join("temp.tif").binwrite @map.read(filename)
        OS.gdal_translate "-of", "PNG", "-co", "ZLEVEL=9", "temp.tif", "/vsistdout/", chdir: tmp
      end.tap do |png|
        (width, height), resolution = size_resolution
        transform = "scale(#{resolution / @map.metres_per_mm})"
        href = "data:image/png;base64,#{Base64.encode64 png}"
        defs.add_element "image", "id" => "#{@name}.content", "transform" => transform, "width" => width, "height" => height, "image-rendering" => "optimizeQuality", "href" => href
      end

      colour, shade, gamma = @params.values_at "colour", "shade", "gamma"
      raise "can't specify both colour and shade values" if colour && shade

      filter = defs.add_element("filter", "id" => "#{@name}.filter") if shade || gamma
      filter.add_element("feColorMatrix", "values" => "-1 0 0 0 1  -1 0 0 0 1  -1 0 0 0 1  0 0 0 1 0", "color-interpolation-filters" => "sRGB") if shade
      filter.add_element("feComponentTransfer", "color-interpolation-filters" => "linearRGB").tap do |transfer|
        transfer.add_element("feFuncR", "type" => "gamma", "exponent" => gamma)
        transfer.add_element("feFuncG", "type" => "gamma", "exponent" => gamma)
        transfer.add_element("feFuncB", "type" => "gamma", "exponent" => gamma)
      end if gamma

      defs.add_element("mask", "id" => "#{@name}.mask").tap do |mask|
        use = mask.add_element("use", "href" => "##{@name}.content")
        use.add_attributes("filter" => "url(##{@name}.filter)") if filter

        cutouts.each.with_object mask.add_element("g", "filter" => "url(#map.filter.cutout)") do |cutout, group|
          group.add_element cutout.use
        end if cutouts.any?
      end

      REXML::Element.new("use").tap do |use|
        use.add_attributes "id" => @name, "mask" => "url(##{@name}.mask)", "href" => "#map.rect", "fill" => shade || colour
        use.add_attributes @params.slice("opacity")
      end.tap(&block)
    end
  end
end

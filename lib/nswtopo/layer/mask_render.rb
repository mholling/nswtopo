module NSWTopo
  module MaskRender
    def render(cutouts:, **, &block)
      colour, shade, gamma = @params.values_at "colour", "shade", "gamma"
      raise "can't specify both colour and shade values" if colour && shade

      REXML::Element.new("defs").tap do |defs|
        defs.add_attributes("id" => "#{@name}.defs")
        defs.add_element(image_element).add_attributes("id" => "#{@name}.content")

        filter = defs.add_element("filter", "id" => "#{@name}.filter") if shade || gamma
        filter.add_element("feColorMatrix", "values" => "-1 0 0 0 1  -1 0 0 0 1  -1 0 0 0 1  0 0 0 1 0", "color-interpolation-filters" => "sRGB") if shade
        filter.add_element("feComponentTransfer", "color-interpolation-filters" => "sRGB").tap do |transfer|
          gamma, clip = [*gamma, 0]
          amplitude, offset = 1 / (1 - clip), clip / (clip - 1)
          transfer.add_element("feFuncR", "type" => "gamma", "exponent" => gamma, "amplitude" => amplitude, "offset" => offset)
          transfer.add_element("feFuncG", "type" => "gamma", "exponent" => gamma, "amplitude" => amplitude, "offset" => offset)
          transfer.add_element("feFuncB", "type" => "gamma", "exponent" => gamma, "amplitude" => amplitude, "offset" => offset)
        end if gamma

        defs.add_element("mask", "id" => "#{@name}.mask").tap do |mask|
          use = mask.add_element("use", "href" => "##{@name}.content")
          use.add_attributes("filter" => "url(##{@name}.filter)") if filter

          cutouts.each.with_object mask.add_element("g", "filter" => "url(#map.filter.cutout)") do |cutout, group|
            group.add_element cutout.use
          end if cutouts.any?
        end
      end.tap(&block)

      REXML::Element.new("use").tap do |use|
        use.add_attributes "id" => @name, "mask" => "url(##{@name}.mask)", "href" => "#map.neatline", "fill" => shade || colour
        use.add_attributes @params.slice("opacity")
      end.tap(&block)
    end
  end
end

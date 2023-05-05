module NSWTopo
  module RasterRender
    def render(**, &block)
      REXML::Element.new("defs").tap do |defs|
        defs.add_attributes("id" => "#{@name}.defs")
        defs.add_element(image_element).add_attributes("id" => "#{@name}.content")
      end.tap(&block)

      REXML::Element.new("use").tap do |use|
        use.add_attributes "id" => @name, "mask" => "none", "href" => "##{@name}.content"
        use.add_attributes params.slice("opacity")
      end.tap(&block)
    end
  end
end

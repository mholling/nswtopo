module NSWTopo
  module Formats
    def render_svg(svg_path, background:, **options)
      if uptodate?("map.svg", "map.yml")
        xml = REXML::Document.new read("map.svg")

      else
        width, height = @extents.times(@mm_per_metre)
        xml = REXML::Document.new
        xml << REXML::XMLDecl.new(1.0, "utf-8")
        svg = xml.add_element "svg",
          "width"  => "#{width}mm",
          "height" => "#{height}mm",
          "viewBox" => "0 0 #{width} #{height}",
          "text-rendering" => "geometricPrecision",
          "xmlns" => "http://www.w3.org/2000/svg"

        svg.add_element("metadata").add_element("rdf:RDF",
          "xmlns:rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
          "xmlns:xmp" => "http://ns.adobe.com/xap/1.0/",
          "xmlns:dc"  => "http://purl.org/dc/elements/1.1/"
        ).add_element("rdf:Description",
          "xmp:CreatorTool" => VERSION.creator_string,
          "xmp:CreateDate" => Time.now.iso8601,
          "dc:format" => "image/svg+xml"
        )

        svg.add_element("defs").tap do |defs|
          defs.add_element("rect", "width" => width, "height" => height, "id" => "map.rect")
          defs.add_element("clipPath", "id" => "map.clip").add_element("use", "href" => "#map.rect")
          defs.add_element("filter", "id" => "map.filter.alpha2mask").add_element("feColorMatrix", "type" => "matrix", "values" => "0 0 0 -1 1   0 0 0 -1 1   0 0 0 -1 1   0 0 0 0 1")
        end
        svg.add_element("use", "id" => "map.background", "href" => "#map.rect", "fill" => "white")

        labels = Layer.new "labels", self, Config.fetch("labels", {}).merge("type" => "Labels")
        layers.reject(&:empty?).each do |layer|
          next if Config["labelling"] == false
          labels.add layer if Vector === layer
        end.push(labels).inject [] do |masks, layer|
          log_update "compositing: #{layer.name}"
          group = svg.add_element "g", "id" => layer.name, "clip-path" => "url(#map.clip)"
          layer.render(group, masks: masks) do |fence: nil, mask: nil|
            labels.add_fence(*fence) if fence
            masks << mask if mask
          end
          masks
        end

        xml.elements.each("svg//defs[not(*)]", &:remove)
        until xml.elements.each("svg//g[not(*)]", &:remove).empty? do
        end

        write "map.svg", xml.to_s
      end

      xml.elements["svg/*[@id='map.background']"].add_attribute "fill", background if background
      xml.elements["svg/metadata/rdf:RDF/rdf:Description"].add_attributes("xmp:ModifyDate" => Time.now.iso8601)
      string, formatter = String.new, REXML::Formatters::Pretty.new
      formatter.compact = true
      formatter.write xml, string
      svg_path.write string
    end
  end
end

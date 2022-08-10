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

        # add defs for map filters and masks
        defs = svg.add_element("defs", "id" => "map.defs")
        defs.add_element("rect", "id" => "map.rect", "width" => width, "height" => height)

        # add a filter converting alpha channel to cutout mask
        defs.add_element("filter", "id" => "map.filter.cutout").tap do |filter|
          filter.add_element("feComponentTransfer", "in" => "SourceAlpha")
        end

        Enumerator.new do |yielder|
          labels = Layer.new "labels", self, Config.fetch("labels", {}).merge("type" => "Labels")
          layers.reject(&:empty?).each do |layer|
            next if Config["labelling"] == false
            labels.add layer if Vector === layer
          end.push(labels).each.with_object [[], []] do |layer, (cutouts, knockouts)|
            log_update "compositing: #{layer.name}"
            layer.render(cutouts: cutouts) do |object|
              case object
              when Labels::Barrier then labels << object
              when Vector::Cutout then cutouts << object
              when Vector::Knockout then knockouts << object
              when REXML::Element then yielder << object
              end
            end
          end.last.group_by(&:buffer).select do |buffer, knockouts|
            buffer.positive?
          end.map do |buffer, knockouts|
            defs.add_element("filter", "id" => "map.filter.knockout.#{buffer}").tap do |filter|
              filter.add_element("feMorphology", "operator" => "dilate", "radius" => 0.4 + buffer, "in" => "SourceAlpha")
              filter.add_element("feMorphology", "operator" => "erode", "radius" => 0.4)
              filter.add_element("feGaussianBlur", "stdDeviation" => 0.2)
              filter.add_element("feComponentTransfer").add_element("feFuncA", "type" => "discrete", "tableValues" => "0 1")
            end
            knockouts.map.with_object REXML::Element.new("g") do |knockout, group|
              group.add_element knockout.use
            end.tap do |group|
              group.add_attributes "filter" => "url(#map.filter.knockout.#{buffer})"
            end
          end.tap do |groups|
            mask = defs.add_element("mask", "id" => "map.mask.knockout")
            mask.add_element("use", "href" => "#map.rect", "fill" => "white")
            groups.each(&mask.method(:add))
          end
        end.reject do |element|
          svg.add_element(element) if "defs" == element.name
        end.tap do
          svg.add_element("use", "id" => "map.background", "href" => "#map.rect", "fill" => "white")
        end.chunk do |element|
          element.attributes["mask"] || "none"
        end.each do |mask, elements|
          elements.each.with_object(svg.add_element("g", "mask" => mask)) do |element, group|
            group.add_element element
            element.delete_attribute "mask"
          end
        end

        xml.elements.each("svg//defs[not(*)]", &:remove)
        write "map.svg", xml.to_s
      end

      xml.elements["svg/use[@id='map.background']"].add_attributes("fill" => background) if background
      xml.elements["svg/metadata/rdf:RDF/rdf:Description"].add_attributes("xmp:ModifyDate" => Time.now.iso8601)

      svg_path.open("w") do |file|
        formatter = REXML::Formatters::Pretty.new
        formatter.compact = true
        formatter.write xml, file
      end
    end
  end
end

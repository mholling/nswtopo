module NSWTopo
  module Formats
    def render_pdf(pdf_path, ppi: nil, background:, **options)
      if ppi
        OS.gdal_translate "-of", "PDF", "-co", "DPI=#{ppi}", "-co", "MARGIN=0", "-co", "CREATOR=nswtopo", "-co", "GEO_ENCODING=ISO32000", yield(ppi: ppi), pdf_path
      else
        Dir.mktmppath do |temp_dir|
          svg_path = temp_dir / "pdf-map.svg"
          render_svg svg_path, background: background

          REXML::Document.new(svg_path.read).tap do |xml|
            xml.elements["svg"].tap do |svg|
              style = "@media print { @page { margin: 0; size: %s %s; } }"
              svg.add_element("style").text = style % svg.attributes.values_at("width", "height")
            end

            # replace fill pattern paint with manual pattern mosaic to work around Chrome PDF bug
            xml.elements.each("//svg//use[@id][@fill][@href]") do |use|
              id = use.attributes["id"]

              # find the pattern id, content id, pattern element and content element
              next unless /^url\(#(?<pattern_id>.*)\)$/ =~ use.attributes["fill"]
              next unless /^#(?<content_id>.*)$/ =~ use.attributes["href"]
              next unless pattern = use.elements["preceding::defs/pattern[@id='#{pattern_id}'][@width][@height]"]
              next unless content = use.elements["preceding::defs/g[@id='#{content_id}']"]

              # change pattern element to a group
              pattern.attributes.delete "patternUnits"
              pattern.name = "g"

              # create a clip path to apply to the fill pattern mosaic
              content_clip = REXML::Element.new "clipPath"
              content_clip.add_attribute "id", "#{content_id}.clip"

              # create a clip path to apply to pattern element
              pattern_clip = REXML::Element.new "clipPath"
              pattern_clip.add_attribute "id", "#{pattern_id}.clip"
              pattern.add_attribute "clip-path", "url(##{pattern_id}.clip)"

              # move content and clip paths into defs
              pattern.previous_sibling = pattern_clip
              pattern.next_sibling = content
              content.next_sibling = content_clip

              # replace fill paint with a container for the fill pattern mosaic
              fill = REXML::Element.new "g"
              fill.add_attribute "clip-path", "url(##{content_id}.clip)"
              fill.add_attribute "id", "#{id}.fill"
              use.previous_sibling = fill
              use.add_attribute "fill", "none"

              xml.elements.each("//use[@href='##{id}']") do |use|
                use_fill = REXML::Element.new "use"
                use_fill.add_attribute "href", "##{id}.fill"
                use.previous_sibling = use_fill
              end

              # get pattern size
              pattern_size = %w[width height].map do |name|
                pattern.attributes[name].tap { pattern.attributes.delete name }
              end.map(&:to_f)

              # create pattern clip
              pattern_size.each.with_object(0).inject(&:product).values_at(3,2,0,1).tap do |corners|
                pattern_clip.add_element "path", "d" => %w[M L L L].zip(corners).push("Z").join(?\s)
              end

              # add paths to content clip, get content coverage area, and create fill pattern mosaic
              content.elements.collect("path[@d]", &:itself).each.with_index do |path, index|
                path.add_attribute "id", "#{content_id}.#{index}"
                content_clip.add_element "use", "href" => "##{content_id}.#{index}"
              end.flat_map do |path|
                path.attributes["d"].scan /(\d+(?:\.\d+)?) (\d+(?:\.\d+)?)/
              end.transpose.map do |coords|
                coords.map(&:to_f).minmax
              end.zip(pattern_size).map do |(min, max), size|
                (min...max).step(size).entries
              end.inject(&:product).each do |x, y|
                fill.add_element "use", "href" => "##{pattern_id}", "x" => x, "y" => y
              end
            end

            svg_path.write xml
          end

          FileUtils.rm pdf_path if pdf_path.exist?
          log_update "chrome: rendering PDF"

          Chrome.with_browser("file://#{svg_path}") do |browser|
            browser.print_to_pdf pdf_path
          end
        end
      end
    end
  end
end

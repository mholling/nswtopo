module NSWTopo
  module Formats
    def render_svg(svg_path, external: nil, **options)
      case
      when external
        raise "not a file: %s" % external unless external.file?
        begin
          svg = REXML::Document.new(external.read).elements["svg"]
          raise "not an SVG file: %s" % external unless svg
          desc = svg.elements["metadata/rdf:RDF/rdf:Description[@dc:creator='nswtopo']"]
          raise "not an nswtopo SVG file: %s" % external unless desc
        rescue REXML::ParseException
          raise "not an SVG file: %s" % external
        end
        FileUtils.cp external, svg_path

      when @archive.uptodate?("map.svg", "map.yml")
        svg_path.write @archive.read("map.svg")

      else
        width, height = extents.times(1000.0 / scale)
        xml = REXML::Document.new
        xml << REXML::XMLDecl.new(1.0, "utf-8")
        svg = xml.add_element "svg",
          "version" => 1.1,
          "baseProfile" => "full",
          "width"  => "#{width}mm",
          "height" => "#{height}mm",
          "viewBox" => "0 0 #{width} #{height}",
          "xmlns"          => "http://www.w3.org/2000/svg",
          "xmlns:xlink"    => "http://www.w3.org/1999/xlink",
          "xmlns:sodipodi" => "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd",
          "xmlns:inkscape" => "http://www.inkscape.org/namespaces/inkscape"

        meta = svg.add_element "metadata"
        rdf = meta.add_element "rdf:RDF",
          "xmlns:rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
          "xmlns:dc"  => "http://purl.org/dc/elements/1.1/"
        rdf.add_element "rdf:Description",
          "dc:date" => Date.today.iso8601,
          "dc:format" => "image/svg+xml",
          "dc:creator" => "nswtopo"

        defs = svg.add_element "defs"
        svg.add_element "sodipodi:namedview", "borderlayer" => true
        svg.add_element "rect", "x" => 0, "y" => 0, "width" => width, "height" => height, "fill" => "white"

        labels = Layer.new "labels", self, Config.fetch("labels", {}).merge("type" => "Labels")
        layers.reject(&:empty?).each do |layer|
          next if Config["labelling"] == false
          labels.add layer if Vector === layer
        end.push(labels).each do |layer|
          log_update "compositing: #{layer.name}"
          group = svg.add_element "g", "id" => layer.name, "inkscape:groupmode" => "layer"
          layer.render group, defs, &labels.method(:add_fence)
        end

        until xml.elements.each("svg//g[not(*)]", &:remove).empty? do
        end

        string, formatter = String.new, REXML::Formatters::Pretty.new
        formatter.compact = true
        formatter.write xml, string
        write "map.svg", string
        svg_path.write string
      end
    end
  end
end

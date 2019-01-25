module NSWTopo
  class GPS
    module KML
      def styles(placemark)
        style_url = placemark.elements["styleUrl"]&.text&.delete_prefix(?#)
        style_element = @xml.elements["/kml/Document/[@id='%s']" % style_url]
        result = {}

        case style_element&.name
        when "StyleMap"
          style_element = style_element.elements["Pair[key[text()='normal']]"]
          result = styles(style_element) if style_element

        when "Style"
          [%w[LineStyle stroke], %w[PolyStyle fill]].each do |element, attribute|
            /^[0-9a-fA-F]{8}$/.match(style_element.elements["#{element}/color"]&.text) do |match|
              a, b, g, r = match[0].each_char.each_slice(2).map(&:join)
              result["#{attribute}-opacity"] = (Float("0x%s" % a) / 255).round(5)
              result[attribute] = Colour.new("#%s%s%s" % [r, g, b]).to_s
            end
          end
          result["stroke"] ||= "#FFFFFF"
          result["stroke-width"] = ((style_element.elements["LineStyle/width"]&.text || 1).to_f * 25.4 / 96.0).round(5)

          [%w[fill fill], %w[outline stroke]].each do |element, attribute|
            if style_element.elements["PolyStyle/#{element}"]&.text == ?0
              result[attribute] = "none"
              result.delete "#{attribute}-opacity"
              result.delete "#{attribute}-width"
            end
          end
        end
        result
      end

      def properties(placemark)
        { "name" => placemark.elements["name"]&.text, "folder" => placemark.elements["ancestor::Folder/name"]&.text }
      end

      def collection
        GeoJSON::Collection.new.tap do |collection|
          @xml.elements.each "/kml//Placemark[Point/coordinates]" do |placemark|
            coords = placemark.elements["Point/coordinates"].text.split(',').take(2).map(&:to_f)
            collection.add_point coords, properties(placemark).merge("styles" => {})
          end
          @xml.elements.each "/kml//Placemark[LineString/coordinates]" do |placemark|
            coords = placemark.elements["LineString/coordinates"].text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) }
            collection.add_linestring coords, properties(placemark).merge("styles" => styles(placemark))
          end
          @xml.elements.each "/kml//Placemark[gx:Track]" do |placemark|
            coords = placemark.elements.collect("gx:Track/gx:coord") { |coord| coord.text.split(?\s).take(2).map(&:to_f) }
            collection.add_linestring coords, properties(placemark).merge("styles" => styles(placemark))
          end
          @xml.elements.each "/kml//Placemark[Polygon/outerBoundaryIs/LinearRing/coordinates]" do |placemark|
            coords = [placemark.elements["Polygon/outerBoundaryIs/LinearRing/coordinates"].text]
            coords += placemark.elements.collect("Polygon/innerBoundaryIs/LinearRing/coordinates", &:text)
            coords.map! do |text|
              text.split(' ').map { |triplet| triplet.split(?,).take(2).map(&:to_f) }
            end
            collection.add_polygon coords, properties(placemark).merge("styles" => styles(placemark))
          end
        end
      end
    end
  end
end

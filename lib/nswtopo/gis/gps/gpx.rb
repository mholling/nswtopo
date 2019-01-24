module NSWTopo
  class GPS
    module GPX
      def collection
        GeoJSON::Collection.new.tap do |collection|
          @xml.elements.each "/gpx/wpt" do |wpt|
            coords = %w[lon lat].map { |name| wpt.attributes[name].to_f }
            name = wpt.elements["name"]&.text
            collection.add_point coords, "name" => name
          end
          @xml.elements.each "/gpx/trk" do |trk|
            coords = trk.elements.collect("trkseg") do |trkseg|
              trkseg.elements.collect("trkpt") { |trkpt| %w[lon lat].map { |name| trkpt.attributes[name].to_f } }
            end
            name = trk.elements["name"]&.text
            collection.add_multilinestring coords, "name" => name
          end
        end
      end
    end
  end
end

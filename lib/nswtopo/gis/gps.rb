module NSWTopo
  module GPS
    def self.load(path)
      xml = REXML::Document.new(path.read)
      raise "invalid GPX or KML file: #{path}" unless xml.elements["/gpx|/kml"]
      GeoJSON::Collection.new.tap do |collection|
        xml.elements.each "/gpx//wpt" do |waypoint|
          coords = [ "lon", "lat" ].map { |name| waypoint.attributes[name].to_f }
          name = waypoint.elements["./name"]&.text.to_s
          collection.add_point coords, "name" => name
        end
        xml.elements.each "/gpx//trk" do |track|
          coords = track.elements.collect(".//trkpt") { |point| [ "lon", "lat" ].map { |name| point.attributes[name].to_f } }
          name = track.elements["./name"]&.text.to_s
          collection.add_linestring coords, "name" => name
        end
        xml.elements.each "/kml//Placemark[.//Point/coordinates]" do |waypoint|
          coords = waypoint.elements[".//Point/coordinates"].text.split(',')[0..1].map(&:to_f)
          name = waypoint.elements["./name"]&.text.to_s
          collection.add_point coords, "name" => name
        end
        xml.elements.each "/kml//Placemark[.//LineString//coordinates]" do |track|
          coords = track.elements[".//LineString//coordinates"].text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) }
          name = track.elements["./name"]&.text.to_s
          collection.add_linestring coords, "name" => name
        end
        xml.elements.each "/kml//Placemark//gx:Track" do |track|
          coords = track.elements.collect("./gx:coord") { |coord| coord.text.split(?\s).take(2).map(&:to_f) }
          name = track.elements["ancestor::/Placemark[1]"].elements["name"]&.text.to_s
          collection.add_linestring coords, "name" => name
        end
        xml.elements.each "/kml//Placemark[.//Polygon//coordinates]" do |polygon|
          coords = polygon.elements[".//Polygon//coordinates"].text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) }
          name = polygon.elements["./name"]&.text.to_s
          collection.add_polygon [ coords ], "name" => name
        end
      end
    rescue Errno::ENOENT
      raise "no such file: #{path}"
    rescue REXML::ParseException
      raise "invalid GPX or KML file: #{path}"
    end
  end
end

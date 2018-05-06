module NSWTopo
  class GPS
    module GPX
      def waypoints
        Enumerator.new do |yielder|
          @xml.elements.each "/gpx//wpt" do |waypoint|
            coords = [ "lon", "lat" ].map { |name| waypoint.attributes[name].to_f }
            name = waypoint.elements["./name"]
            yielder << [ coords, name ? name.text : "" ]
          end
        end
      end
      
      def tracks
        Enumerator.new do |yielder|
          @xml.elements.each "/gpx//trk" do |track|
            list = track.elements.collect(".//trkpt") { |point| [ "lon", "lat" ].map { |name| point.attributes[name].to_f } }
            name = track.elements["./name"]
            yielder << [ list, name ? name.text : "" ]
          end
        end
      end
      
      def areas
        Enumerator.new { |yielder| }
      end
    end

    module KML
      def waypoints
        Enumerator.new do |yielder|
          @xml.elements.each "/kml//Placemark[.//Point/coordinates]" do |waypoint|
            coords = waypoint.elements[".//Point/coordinates"].text.split(',')[0..1].map(&:to_f)
            name = waypoint.elements["./name"]
            yielder << [ coords, name ? name.text : "" ]
          end
        end
      end
      
      def tracks
        Enumerator.new do |yielder|
          @xml.elements.each "/kml//Placemark[.//LineString//coordinates]" do |track|
            list = track.elements[".//LineString//coordinates"].text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) }
            name = track.elements["./name"]
            yielder << [ list, name ? name.text : "" ]
          end
          @xml.elements.each "/kml//Placemark//gx:Track" do |track|
            list = track.elements.collect("./gx:coord") { |coord| coord.text.split(?\s).take(2).map(&:to_f) }
            name = track.elements["ancestor::/Placemark[1]"].elements["name"]
            yielder << [ list, name ? name.text : "" ]
          end
        end
      end
      
      def areas
        Enumerator.new do |yielder|
          @xml.elements.each "/kml//Placemark[.//Polygon//coordinates]" do |polygon|
            list = polygon.elements[".//Polygon//coordinates"].text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) }
            name = polygon.elements["./name"]
            yielder << [ list, name ? name.text : "" ]
          end
        end
      end
    end

    def initialize(path)
      @xml = REXML::Document.new(path.read)
      case
      when @xml.elements["/gpx"] then class << self; include GPX; end
      when @xml.elements["/kml"] then class << self; include KML; end
      else raise BadGpxKmlFile.new(path.to_s)
      end
    rescue REXML::ParseException, Errno::ENOENT
      raise BadGpxKmlFile.new(path.to_s)
    end
  end
end

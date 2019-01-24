require_relative 'gps/gpx'
require_relative 'gps/kml'

module NSWTopo
  class GPS
    def initialize(path)
      @xml = REXML::Document.new(path.read)
      case
      when @xml.elements["/gpx"] then extend GPX
      when @xml.elements["/kml"] then extend KML
      else
        raise "invalid GPX or KML file: #{path}"
      end
    end

    def self.load(path)
      new(path).collection
    end
  end
end

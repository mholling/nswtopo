module NSWTopo
  class Projection
    def initialize(value)
      @wkt_simple = Projection === value ? value.wkt_simple : OS.gdalsrsinfo("-o", "wkt_simple", "--single-line", value).chomp.strip
      raise "no georeferencing found: %s" % value if @wkt_simple.empty?
    end

    attr_reader :wkt_simple
    alias to_s wkt_simple
    alias to_str wkt_simple

    def proj4
      @proj4 ||= OS.gdalsrsinfo("-o", "proj4", "--single-line", @wkt_simple).chomp.strip
    end

    def ==(other)
      wkt_simple == other.wkt_simple
    end

    extend Forwardable
    delegate :hash => :@wkt_simple
    alias eql? ==

    def self.utm(zone, south: true)
      new("EPSG:32%1d%02d" % [south ? 7 : 6, zone])
    end

    def self.wgs84
      new("EPSG:4326")
    end

    def self.transverse_mercator(lon, lat)
      new("+proj=tmerc +lon_0=#{lon} +lat_0=#{lat} +k=1 +x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs")
    end

    def self.azimuthal_equidistant(lon, lat)
      new("+proj=aeqd +lon_0=#{lon} +lat_0=#{lat} +k_0=1 +x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs")
    end

    def self.utm_zones(collection)
      collection.reproject_to_wgs84.bounds.first.map do |longitude|
        (longitude / 6).floor + 31
      end.yield_self do |min, max|
        min..max
      end
    end

    def self.utm_hull(zone)
      longitudes = [31, 30].map { |offset| (zone - offset) * 6.0 }
      latitudes = [-80.0, 84.0]
      longitudes.product(latitudes).values_at(0,2,3,1)
    end
  end
end

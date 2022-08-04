module NSWTopo
  class Projection
    def initialize(value)
      @wkt = Projection === value ? value.wkt : OS.gdalsrsinfo("-o", "wkt1", "--single-line", value).chomp.strip
      raise "no georeferencing found: %s" % value if @wkt.empty?
    end

    attr_reader :wkt
    alias to_s wkt
    alias to_str wkt

    def ==(other)
      wkt == other.wkt
    end

    extend Forwardable
    delegate :hash => :@wkt
    alias eql? ==

    def metres?
      OS.gdalsrsinfo("-o", "proj4", "--single-line", @wkt).chomp.split.any?("+units=m")
    end

    def self.utm(zone, south: true)
      new("EPSG:32%1d%02d" % [south ? 7 : 6, zone])
    end

    def self.wgs84
      new("EPSG:4326")
    end

    def self.transverse_mercator(lon, lat)
      new("+proj=tmerc +lon_0=#{lon} +lat_0=#{lat} +datum=WGS84")
    end

    def self.oblique_mercator(lon, lat, alpha)
      new("+proj=omerc +lonc=#{lon} +lat_0=#{lat} +alpha=#{alpha} +gamma=0 +datum=WGS84")
    end

    def self.azimuthal_equidistant(lon, lat)
      new("+proj=aeqd +lon_0=#{lon} +lat_0=#{lat} +datum=WGS84")
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

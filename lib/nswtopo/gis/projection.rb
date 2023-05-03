module NSWTopo
  class Projection
    def initialize(value)
      @wkt2 = Projection === value ? value.wkt2 : OS.gdalsrsinfo("-o", "wkt2", "--single-line", value).chomp.strip
      raise "no georeferencing found: %s" % value if @wkt2.empty?
    end

    attr_reader :wkt2
    alias to_s wkt2
    alias to_str wkt2

    def ==(other)
      wkt2 == other.wkt2
    end

    extend Forwardable
    delegate :hash => :@wkt2
    alias eql? ==

    def metres?
      OS.gdalsrsinfo("-o", "proj4", "--single-line", @wkt2).chomp.split.any?("+units=m")
    end

    def self.utm(zone, south: true)
      new("EPSG:32%1d%02d" % [south ? 7 : 6, zone])
    end

    def self.wgs84
      new("EPSG:4326")
    end

    def self.from(**params)
      params.map do |key, value|
        "+#{key}=#{value}"
      end.then do |args|
        new args.join(?\s)
      end
    end

    def self.transverse_mercator(lon_0, lat_0, **params)
      from proj: "tmerc", datum: "WGS84", lon_0: lon_0, lat_0: lat_0, **params
    end

    def self.oblique_mercator(lonc, lat_0, alpha:, **params)
      from proj: "omerc", datum: "WGS84", lonc: lonc, lat_0: lat_0, gamma: 0, alpha: alpha, **params
    end

    def self.azimuthal_equidistant(lon_0, lat_0)
      from proj: "aeqd", datum: "WGS84", lon_0: lon_0, lat_0: lat_0
    end

    def self.utm_zones(collection)
      collection.reproject_to_wgs84.bounds.first.map do |longitude|
        (longitude / 6).floor + 31
      end.then do |min, max|
        min..max
      end
    end

    def self.utm_geometry(zone)
      longitudes = [31, 30].map { |offset| (zone - offset) * 6.0 }
      latitudes = [-80.0, 84.0]
      ring = longitudes.product(latitudes).values_at(0,2,3,1,0)
      GeoJSON.polygon [ring], projection: Projection.wgs84
    end
  end
end

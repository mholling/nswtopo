module NSWTopo
  class Projection
    def initialize(string_or_path)
      @proj4 = OS.gdalsrsinfo("-o", "proj4", string_or_path).chomp.strip
      raise "no georeferencing found: %s" % string_or_path if @proj4.empty?
    end

    %w[wkt wkt_simple wkt_noct wkt_esri mapinfo xml].each do |format|
      define_method format do
        OS.gdalsrsinfo("-o", format, @proj4).split(/['\r\n]+/).map(&:strip).join("")
      end
    end

    attr_reader :proj4
    alias to_s proj4
    alias to_str proj4

    def ==(other)
      proj4 == other.proj4
    end

    extend Forwardable
    delegate :hash => :@proj4
    alias eql? ==

    def self.utm(zone, south = true)
      new("+proj=utm +zone=#{zone}#{' +south' if south} +ellps=WGS84 +datum=WGS84 +units=m +no_defs")
    end

    def self.wgs84
      new("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")
    end

    def self.transverse_mercator(lon, lat)
      new("+proj=tmerc +lon_0=#{lon} +lat_0=#{lat} +k=1 +x_0=0 +y_0=0 +ellps=WGS84 +datum=WGS84 +units=m +no_defs")
    end

    def self.azimuthal_equidistant(lon, lat)
      new("+proj=aeqd +lon_0=#{lon} +lat_0=#{lat} +k_0=1 +x_0=0 +y_0=0 +ellps=WGS84 +datum=WGS84 +units=m +no_defs")
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

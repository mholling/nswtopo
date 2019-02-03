module NSWTopo
  module GeoJSON
    class Collection
      def initialize(projection = Projection.wgs84, features = [])
        @projection, @features = projection, features
      end
      attr_reader :projection, :features

      def self.load(json, projection = nil)
        collection = JSON.parse(json)
        proj4 = collection.dig "crs", "properties", "name"
        projection ||= proj4 ? Projection.new(proj4) : Projection.wgs84
        collection["features"].map do |feature|
          geometry, properties = feature.values_at "geometry", "properties"
          type, coordinates = geometry.values_at "type", "coordinates"
          raise Error, "unsupported geometry type: #{type}" unless TYPES === type
          GeoJSON.const_get(type).new coordinates, properties
        end.yield_self do |features|
          new projection, features
        end
      rescue JSON::ParserError
        raise Error, "invalid GeoJSON data"
      end

      def <<(feature)
        tap { @features << feature }
      end
      alias push <<

      include Enumerable
      def each(&block)
        block_given? ? tap { @features.each(&block) } : @features.each
      end

      def reproject_to(projection)
        return self if self.projection == projection
        json = OS.ogr2ogr "-t_srs", projection, "-f", "GeoJSON", "-lco", "RFC7946=NO", "/vsistdout/", "GeoJSON:/vsistdin/" do |stdin|
          stdin.puts to_json
        end
        Collection.load json, projection
      end

      def reproject_to_wgs84
        reproject_to Projection.wgs84
      end

      def to_h
        {
          "type" => "FeatureCollection",
          "crs" => { "type" => "name", "properties" => { "name" => @projection } },
          "features" => map(&:to_h)
        }
      end

      extend Forwardable
      delegate %i[coordinates properties] => :first
      delegate %i[reject! select!] => :@features

      def to_json(**extras)
        to_h.merge(extras).to_json
      end

      def explode
        Collection.new @projection, flat_map(&:explode)
      end

      def multi
        Collection.new @projection, map(&:multi)
      end

      def merge(other)
        raise Error, "can't merge different projections" unless @projection == other.projection
        Collection.new @projection, @features + other.features
      end

      def merge!(other)
        raise Error, "can't merge different projections" unless @projection == other.projection
        tap { @features.concat other.features }
      end

      def clip!(hull)
        @features.map! do |feature|
          feature.clip hull
        end.compact!
        self
      end

      # TODO: what about empty collections?
      def bounds
        map(&:bounds).transpose.map(&:flatten).map(&:minmax)
      end
    end
  end
end

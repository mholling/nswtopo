module NSWTopo
  module GeoJSON
    DEFAULT_PROJECTION = Projection.wgs84

    class Collection
      def initialize(projection: DEFAULT_PROJECTION, features: [], name: nil)
        @projection, @features, @name = projection, features, name
      end
      attr_reader :projection, :features, :name

      def self.load(json, projection = nil)
        collection = JSON.parse(json)
        crs_name = collection.dig "crs", "properties", "name"
        projection ||= crs_name ? Projection.new(crs_name) : DEFAULT_PROJECTION
        collection["features"].map do |feature|
          geometry, properties = feature.values_at "geometry", "properties"
          type, coordinates = geometry.values_at "type", "coordinates"
          raise Error, "unsupported geometry type: #{type}" unless TYPES === type
          GeoJSON.const_get(type).new coordinates, properties
        end.then do |features|
          new projection: projection, features: features, name: collection["name"]
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
        }.tap do |hash|
          hash["name"] = @name if @name
        end
      end

      extend Forwardable
      delegate %i[coordinates properties] => :first
      delegate %i[reject! select!] => :@features

      def to_json(**extras)
        to_h.merge(extras).to_json
      end

      def explode
        Collection.new projection: @projection, features: flat_map(&:explode)
      end

      def multi
        Collection.new projection: @projection, features: map(&:multi)
      end

      def merge(other)
        raise Error, "can't merge different projections" unless @projection == other.projection
        Collection.new projection: @projection, features: @features + other.features
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

      def rename(name = nil)
        tap { @name = name }
      end

      # TODO: what about empty collections?
      def bounds
        map(&:bounds).transpose.map(&:flatten).map(&:minmax)
      end

      def bbox
        GeoJSON.polygon [bounds.inject(&:product).values_at(0,2,3,1,0)], projection: @projection
      end
    end
  end
end

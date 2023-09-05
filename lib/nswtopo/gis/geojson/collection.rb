module NSWTopo
  module GeoJSON
    DEFAULT_PROJECTION = Projection.wgs84

    class Collection
      def initialize(projection: DEFAULT_PROJECTION, features: [], name: nil)
        @projection, @features, @name = projection, features, name
      end
      attr_reader :projection, :features, :name

      def self.load(json, projection: nil, name: nil)
        collection = JSON.parse(json)
        crs_name = collection.dig "crs", "properties", "name"
        projection ||= crs_name ? Projection.new(crs_name) : DEFAULT_PROJECTION
        name ||= collection["name"]
        collection["features"].select do |feature|
          feature["geometry"]
        end.map do |feature|
          geometry, properties = feature.values_at "geometry", "properties"
          type, coordinates = geometry.values_at "type", "coordinates"
          raise Error, "unsupported geometry type: #{type}" unless TYPES === type
          GeoJSON.const_get(type)[coordinates, properties]
        end.then do |features|
          new projection: projection, features: features, name: name
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

      def map!(&block)
        tap { @features.map!(&block) }
      end

      def reject!(&block)
        tap { @features.reject!(&block) }
      end

      def reproject_to(projection)
        return self if self.projection == projection
        json = OS.ogr2ogr "-t_srs", projection, "-f", "GeoJSON", "-lco", "RFC7946=NO", "/vsistdout/", "GeoJSON:/vsistdin/" do |stdin|
          stdin.puts to_json
        end
        Collection.load json, projection: projection
      end

      def reproject_to_wgs84
        reproject_to Projection.wgs84
      end

      def to_h
        {
          "type" => "FeatureCollection",
          "name" => @name,
          "crs" => { "type" => "name", "properties" => { "name" => @projection } },
          "features" => map(&:to_h)
        }.compact
      end

      extend Forwardable
      delegate %i[coordinates properties wkt area svg_path_data] => :first
      delegate %i[length] => :@features

      def to_json(**extras)
        to_h.merge(extras).to_json
      end

      def with_features(features)
        Collection.new projection: @projection, name: @name, features: features
      end

      def with_name(name)
        Collection.new projection: @projection, name: name, features: @features
      end

      def with_sql(sql, name: @name)
        json = OS.ogr2ogr *%w[-f GeoJSON -lco RFC7946=NO /vsistdout/ GeoJSON:/vsistdin/ -dialect SQLite -sql], sql do |stdin|
          stdin.puts to_json
        end
        Collection.load(json, projection: @projection).with_name(name)
      rescue OS::Error
        raise "GDAL with SQLite support required"
      end

      def explode
        with_features flat_map(&:explode)
      end

      def multi
        with_features map(&:multi)
      end

      def merge(other)
        raise Error, "can't merge different projections" unless @projection == other.projection
        with_features @features + other.features
      end

      def merge!(other)
        raise Error, "can't merge different projections" unless @projection == other.projection
        tap { @features.concat other.features }
      end

      def dissolve_points
        with_features map(&:dissolve_points)
      end

      def union
        return self if none?
        with_features [inject(&:+)]
      end

      def rotate_by_degrees!(angle)
        map! { |feature| feature.rotate_by_degrees(angle) }
      end

      def clip(polygon)
        OS.ogr2ogr "-f", "GeoJSON", "-lco", "RFC7946=NO", "-clipsrc", polygon.wkt, "/vsistdout/", "GeoJSON:/vsistdin/" do |stdin|
          stdin.puts to_json
        end.then do |json|
          Collection.load json, projection: @projection
        end
      end

      def buffer(*margins, **options)
        map do |feature|
          feature.buffer(*margins, **options)
        end.then do |features|
          with_features features
        end
      end

      # TODO: what about empty collections?
      def bounds
        map(&:bounds).transpose.map(&:flatten).map(&:minmax)
      end

      def bbox
        GeoJSON.polygon [bounds.inject(&:product).values_at(0,2,3,1,0)], projection: @projection
      end

      def bbox_centre
        midpoint = bounds.map { |min, max| (max + min) / 2 }
        GeoJSON.point midpoint, projection: @projection
      end

      def bbox_extents
        bounds.map { |min, max| max - min }
      end

      def minimum_bbox_angle(*margins)
        dissolve_points.union.first.minimum_bbox_angle(*margins)
      end
    end
  end
end

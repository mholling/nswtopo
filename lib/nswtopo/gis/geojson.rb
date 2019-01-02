module NSWTopo
  module GeoJSON
    Error = Class.new StandardError
    NotImplemented = Class.new Error
    ParserError = Class.new Error

    TYPES = Set.new %W[Point MultiPoint LineString MultiLineString Polygon MultiPolygon]

    CLASSES = TYPES.map do |type|
      klass = Class.new do
        def initialize(coordinates, properties = {})
          raise Error, "invalid feature properties" unless Hash === properties
          @coordinates, @properties = coordinates, properties
        end
        attr_reader :coordinates, :properties

        define_method :to_h do
          {
            "type" => "Feature",
            "geometry" => {
              "type" => type,
              "coordinates" => @coordinates
            },
            "properties" => @properties
          }
        end

        def to_points
          case self
          when Point then [ @coordinates ]
          when MultiPoint, LineString then @coordinates
          when MultiLineString, Polygon then @coordinates.flatten(1)
          when MultiPolygon then @coordinates.flatten(2)
          end
        end
      end

      const_set type, klass
    end

    class Collection
      def initialize(projection = Projection.wgs84, features = [])
        @projection, @features = projection, features
      end
      attr_reader :projection, :features

      def self.load(json, projection = nil)
        collection = JSON.parse(json)
        projection ||= Projection.new(collection.dig("crs", "properties", "name") || "EPSG:4326")
        collection["features"].map do |feature|
          geometry, properties = feature.values_at "geometry", "properties"
          type, coordinates = geometry.values_at "type", "coordinates"
          raise NotImplemented, type unless TYPES === type
          GeoJSON.const_get(type).new coordinates, properties
        end.yield_self do |features|
          new projection, features
        end
      rescue JSON::ParserError
        raise ParserError
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
        # TODO: set SIGNIFICANT_FIGURES and/or COORDINATE_PRECISION layer creation option?
        json = OS.ogr2ogr "-t_srs", projection, "-f", "GeoJSON", "-lco", "RFC7946=NO", "/vsistdout/", "/vsistdin/" do |stdin|
          stdin.puts to_json
        end
        GeoJSON::Collection.load json, projection
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
      delegate [ :coordinates, :properties ] => :first

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

      CLASSES.zip(TYPES).each do |klass, type|
        define_method "add_#{type}".downcase do |coordinates, properties = {}|
          self << klass.new(coordinates, properties)
        end

        define_method "#{type}s".downcase do
          grep klass
        end
      end

      def clip!(hull)
        @features.map! do |feature|
          feature.clip hull
        end.compact!
        self
      end
    end

    [ [ Point,      MultiPoint      ],
      [ LineString, MultiLineString ],
      [ Polygon,    MultiPolygon    ] ].each do |single_class, multi_class|
      [ single_class, multi_class ].each do |klass|
        klass.class_eval do
          define_method :clip do |hull|
            clipped = multi_class.clip klass == multi_class ? @coordinates : [ @coordinates ], hull
            case
            when clipped.none?
            when clipped.one?
              single_class.new clipped.first, @properties
            else
              multi_class.new clipped, @properties
            end
          end
        end
      end

      single_class.class_eval do
        def explode
          [ self ]
        end

        define_method :multi do
          multi_class.new [ @coordinates ], @properties
        end
      end

      multi_class.class_eval do
        define_method :explode do
          @coordinates.map do |coordinates|
            single_class.new coordinates, @properties
          end
        end

        def multi
          self
        end
      end
    end

    class MultiPoint
      def self.clip(points, hull)
        [ hull, hull.perps ].transpose.inject(points) do |result, (vertex, perp)|
          result.select { |point| point.minus(vertex).dot(perp) >= 0 }
        end
      end
    end

    class MultiLineString
      def self.clip(linestrings, hull)
        [ hull, hull.perps ].transpose.inject(linestrings) do |result, (vertex, perp)|
          result.inject([]) do |clipped, points|
            clipped + [ *points, points.last ].segments.inject([[]]) do |lines, segment|
              inside = segment.map { |point| point.minus(vertex).dot(perp) >= 0 }
              case
              when inside.all?
                lines.last << segment[0]
              when inside[0]
                lines.last << segment[0]
                lines.last << segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
              when inside[1]
                lines << [ ]
                lines.last << segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
              end
              lines
            end
          end
        end.select(&:many?)
      end
    end

    class MultiPolygon
      def self.clip(polygons, hull)
        polygons.inject([]) do |result, rings|
          lefthanded = rings.first.clockwise?
          interior, exterior = hull.zip(hull.perps).inject(rings) do |rings, (vertex, perp)|
            insides, neighbours, clipped = Hash[].compare_by_identity, Hash[].compare_by_identity, []
            rings.each do |points|
              points.map do |point|
                point.minus(vertex).dot(perp) >= 0
              end.segments.zip(points.segments).each do |inside, segment|
                insides[segment] = inside
                neighbours[segment] = [ nil, nil ]
              end.map(&:last).ring.each do |segment0, segment1|
                neighbours[segment1][0], neighbours[segment0][1] = segment0, segment1
              end
            end
            neighbours.select! do |segment, _|
              insides[segment].any?
            end
            insides.select do |segment, inside|
              inside.inject(&:^)
            end.each do |segment, inside|
              segment[inside[0] ? 1 : 0] = segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
            end.sort_by do |segment, inside|
              segment[inside[0] ? 1 : 0].minus(vertex).cross(perp) * (lefthanded ? -1 : 1)
            end.map(&:first).each_slice(2) do |segment0, segment1|
              segment = [ segment0[1], segment1[0] ]
              neighbours[segment0][1] = neighbours[segment1][0] = segment
              neighbours[segment] = [ segment0, segment1 ]
            end
            while neighbours.any?
              segment, * = neighbours.first
              clipped << []
              while neighbours.include? segment
                clipped.last << segment[0]
                *, segment = neighbours.delete(segment)
              end
              clipped.last << clipped.last.first
            end
            clipped
          end.partition(&:clockwise?).rotate(lefthanded ? 1 : 0)
          next result << exterior + interior if exterior.one?
          exterior.inject(result) do |result, exterior_ring|
            within, interior = interior.partition do |interior_ring|
              interior_ring.first.within? exterior_ring
            end
            result << [ exterior_ring, *within ]
          end
        end
      end
    end

    class << self
      CLASSES.zip(TYPES).each do |klass, type|
        define_method type.downcase do |coordinates, projection = nil, properties = {}|
          Collection.new(*projection) << klass.new(coordinates, properties)
        end
      end
    end

    class LineString
      def length; @coordinates.path_length end
    end

    class MultiLineString
      def length; @coordinates.sum(&:path_length) end
    end

    class Polygon
      def area; @coordinates.sum(&:signed_area) end
    end

    class MultiPolygon
      def area; @coordinates.flatten(1).sum(&:signed_area) end
    end
  end
end

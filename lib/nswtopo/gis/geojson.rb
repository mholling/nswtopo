require_relative 'geojson/collection'

module NSWTopo
  module GeoJSON
    Error = Class.new StandardError
    TYPES = Set.new %W[Point MultiPoint LineString MultiLineString Polygon MultiPolygon]

    CLASSES = TYPES.map do |type|
      klass = Class.new do
        extend Forwardable

        def initialize(coordinates, properties = {})
          properties ||= {}
          raise Error, "invalid feature properties" unless Hash === properties
          raise Error, "invalid feature geometry" unless Array === coordinates
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

        def bounds
          coordinates.flatten.each_slice(2).entries.transpose.map(&:minmax)
        end
      end

      const_set type, klass
    end

    CLASSES.zip(TYPES).each do |klass, type|
      Collection.define_method "add_#{type}".downcase do |coordinates, properties = {}|
        self << klass.new(coordinates, properties)
      end

      Collection.define_method "#{type}s".downcase do
        grep klass
      end

      define_singleton_method type.downcase do |coordinates, projection = nil|
        Collection.new(*projection) << klass.new(coordinates)
      end
    end

    [[Point,      MultiPoint     ],
     [LineString, MultiLineString],
     [Polygon,    MultiPolygon   ]].each do |single_class, multi_class|
      single_class.class_eval do
        def explode
          [self]
        end

        define_method :multi do
          multi_class.new [@coordinates], @properties
        end

        delegate :clip => :multi
      end

      multi_class.class_eval do
        define_method :explode do
          @coordinates.map do |coordinates|
            single_class.new coordinates, @properties
          end
        end

        delegate :empty? => :@coordinates

        alias multi itself
      end
    end
  end
end

require_relative 'geojson/point'
require_relative 'geojson/line_string'
require_relative 'geojson/polygon'
require_relative 'geojson/multi_point'
require_relative 'geojson/multi_line_string'
require_relative 'geojson/multi_polygon'

require_relative 'geojson/collection'

module NSWTopo
  module GeoJSON
    Error = Class.new StandardError
    TYPES = Set.new %W[Point MultiPoint LineString MultiLineString Polygon MultiPolygon]

    CLASSES = TYPES.map do |type|
      klass = Class.new do
        def initialize(coordinates, properties = {})
          properties ||= {}
          raise Error, "invalid feature properties" unless Hash === properties
          raise Error, "invalid feature geometry" unless Array === coordinates
          @coordinates, @properties = coordinates, properties
        end
        attr_accessor :coordinates, :properties

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

        extend Forwardable
        delegate %i[[] []= fetch values_at key? store clear] => :@properties
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

      define_singleton_method type.downcase do |coordinates, projection: nil, properties: {}|
        Collection.new(*projection) << klass.new(coordinates, properties)
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

        def bounds
          explode.map(&:bounds).transpose.map(&:flatten).map(&:minmax)
        end

        delegate :empty? => :@coordinates

        alias multi dup
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

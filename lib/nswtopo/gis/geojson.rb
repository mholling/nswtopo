require_relative 'geojson/collection'

module NSWTopo
  module GeoJSON
    Error = Class.new StandardError
    TYPES = Set.new %W[Point MultiPoint LineString MultiLineString Polygon MultiPolygon]

    CLASSES = TYPES.map do |type|
      klass = Class.new do
        def initialize(coordinates, properties = nil, &block)
          @coordinates, @properties = coordinates, properties || {}
          raise Error, "invalid feature properties" unless Hash === @properties
          instance_eval(&block) if block_given?
          freeze!
        end

        attr_reader :coordinates, :properties

        extend Forwardable
        delegate %i[[] []= fetch values_at key?] => :@properties
        delegate %i[empty?] => :@coordinates
      end

      klass.define_method :to_h do
        {
          "type" => "Feature",
          "geometry" => {
            "type" => type,
            "coordinates" => @coordinates
          },
          "properties" => @properties
        }
      end

      klass.define_method :with_properties do |properties|
        klass.new @coordinates, properties
      end

      const_set type, klass
    end

    CLASSES.zip(TYPES).each do |klass, type|
      Collection.define_method "add_#{type}".downcase do |coordinates, properties = nil|
        self << klass[coordinates, properties]
      end

      Collection.define_method "#{type}s".downcase do
        grep klass
      end

      Collection.define_method "#{type}?".downcase do
        one? && klass === first
      end

      define_singleton_method type.downcase do |coordinates, projection: DEFAULT_PROJECTION, name: nil, properties: nil|
        Collection.new(projection: projection, name: name) << klass[coordinates, properties]
      end
    end

    [ [Point,      MultiPoint     ],
      [LineString, MultiLineString],
      [Polygon,    MultiPolygon   ]
    ].each do |single_class, multi_class|
      single_class.class_eval do
        include Enumerable
        delegate %i[each] => :@coordinates
        delegate %i[clip dissolve_points +] => :multi

        def explode = [self]
      end

      single_class.define_method :multi do
        multi_class.new [@coordinates], @properties
      end

      multi_class.class_eval do
        include Enumerable

        alias explode entries
        alias multi itself

        def bounds
          map(&:bounds).transpose.map(&:flatten).map(&:minmax)
        end

        def empty_points = MultiPoint.new([], @properties)
        def empty_linestrings = MultiLineString.new([], @properties)
        def empty_polygons = MultiPolygon.new([], @properties)
      end

      multi_class.define_singleton_method :[] do |coordinates, properties = nil, &block|
        multi_class.new(coordinates, properties) do
          @coordinates.each do |coordinates|
            single_class[coordinates]
          end
          block&.call self
        end
      end

      multi_class.define_method :each do |&block|
        enum = Enumerator.new do |yielder|
          @coordinates.each do |coordinates|
            yielder << single_class.new(coordinates, @properties)
          end
        end
        block ? enum.each(&block) : enum
      end

      multi_class.define_method :freeze! do
        each { }
        @coordinates.freeze
        freeze
      end

      multi_class.define_method :empty do
        multi_class.new([], @properties)
      end

      multi_class.define_method :+ do |other|
        case other
        when single_class
          multi_class.new @coordinates + [other.coordinates], @properties
        when multi_class
          multi_class.new @coordinates + other.coordinates, @properties
        else
          raise "heterogenous geometries not implemented"
        end
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

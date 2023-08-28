require_relative 'geojson/collection'

module NSWTopo
  module GeoJSON
    Error = Class.new StandardError
    TYPES = Set.new %W[Point MultiPoint LineString MultiLineString Polygon MultiPolygon]

    CLASSES = TYPES.map do |type|
      klass = Class.new do
        def initialize(coordinates, properties = nil)
          @coordinates, @properties = coordinates, properties || {}
          raise Error, "invalid feature properties" unless Hash === @properties
        end

        def self.[](coordinates, properties = nil)
          new(coordinates, properties).tap(&:sanitise!)
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
        delegate %i[empty?] => :@coordinates
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

        def explode = [self]

        define_method :multi do
          multi_class.new [@coordinates], @properties
        end

        delegate %i[clip dissolve_points +] => :multi
      end

      multi_class.class_eval do
        include Enumerable
        define_method :each do |&block|
          Enumerator.new do |yielder|
            @coordinates.each do |coordinates|
              yielder << single_class.new(coordinates, @properties)
            end
          end.then do |enum|
            block ? enum.each(&block) : enum
          end
        end

        def sanitise! = each(&:sanitise!)
        def explode = entries

        def bounds
          map(&:bounds).transpose.map(&:flatten).map(&:minmax)
        end

        alias multi dup

        define_method :+ do |other|
          case other
          when single_class
            multi_class.new @coordinates + [other.coordinates], @properties
          when multi_class
            multi_class.new @coordinates + other.coordinates, @properties
          else
            raise "heterogenous geometries not implemented"
          end
        end

        def reject!(&block)
          @coordinates.replace explode.reject(&block).map(&:coordinates)
          self
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

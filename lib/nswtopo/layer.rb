require_relative 'layer/raster'
require_relative 'layer/vector'
require_relative 'layer/vegetation'
require_relative 'layer/import'
require_relative 'layer/arcgis_raster'
require_relative 'layer/feature'
require_relative 'layer/contour'
require_relative 'layer/spot'
require_relative 'layer/overlay'
require_relative 'layer/relief'
require_relative 'layer/grid'
require_relative 'layer/declination'
require_relative 'layer/control'
require_relative 'layer/labels'

module NSWTopo
  class Layer
    TYPES = Set[Vegetation, Import, ArcGISRaster, Feature, Contour, Spot, Overlay, Relief, Grid, Declination, Control, Labels]

    def initialize(name, map, params)
      @type = begin
        NSWTopo.const_get params["type"]
      rescue NameError, TypeError
      end

      raise "unrecognised layer type: %s" % params["type"].inspect unless TYPES === @type
      extend @type

      @params = @type.const_defined?(:DEFAULTS) ? @type.const_get(:DEFAULTS).transform_keys(&:to_s).merge(params) : params
      @name, @map, @source, @path, @resolution = Layer.sanitise(name), map, @params.delete("source"), @params.delete("path"), @params.delete("resolution")

      @type.const_get(:CREATE).map(&:to_s).each do |attr|
        instance_variable_set ?@ + attr.tr_s(?-, ?_), @params.delete(attr)
      end if @type.const_defined?(:CREATE)
    end

    attr_reader :name, :params
    alias to_s name

    def level
      case
      when Vegetation   == @type then 0
      when Import       == @type then 1
      when ArcGISRaster == @type then 1
      when Feature      == @type then 2
      when Contour      == @type then 2
      when Spot         == @type then 2
      when Overlay      == @type then 3
      when Relief       == @type then 4
      when Grid         == @type then 5
      when Declination  == @type then 6
      when Control      == @type then 7
      when Labels       == @type then 99
      end
    end

    def <=>(other)
      [self, other].map(&:level).inject(&:<=>)
    end

    def ==(other)
      Layer === other && self.name == other.name
    end

    def uptodate?
      mtimes = [@source&.mtime, @map.mtime(filename)]
      mtimes.all? && mtimes.inject(&:<)
    end

    def pair
      return name, params
    end

    def self.sanitise(name)
      name&.tr_s '^_a-zA-Z0-9*\-', ?.
    end
  end
end

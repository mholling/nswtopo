require_relative 'layer/raster'
require_relative 'layer/vector'
require_relative 'layer/arcgis_raster'
require_relative 'layer/control'
require_relative 'layer/declination'
require_relative 'layer/feature'
require_relative 'layer/grid'
require_relative 'layer/import'
require_relative 'layer/label'
require_relative 'layer/overlay'
require_relative 'layer/relief'
require_relative 'layer/vegetation'

module NSWTopo
  class Layer
    TYPES = Set[Vegetation, Import, ArcGISRaster, Feature, Relief, Overlay, Grid, Declination, Control]

    def initialize(name, map, params)
      # TODO: sanitise name to remove spaces etc.
      @name, @map, @source, @path = name, map, params.delete("source"), params.delete("path")

      @type = begin
        NSWTopo.const_get params["type"]
      rescue NameError, TypeError
      end

      raise "unrecognised layer type: %s" % params["type"].inspect unless TYPES === @type
      extend @type

      @params = @type.const_defined?(:DEFAULTS) ? @type.const_get(:DEFAULTS).transform_keys(&:to_s).merge(params) : params

      @type.const_get(:CREATE).map(&:to_s).each do |attr|
        instance_variable_set ?@ + attr, @params.delete(attr)
      end if @type.const_defined?(:CREATE)

      @paths = [ *@path ].map do |path|
        Pathname(path).expand_path(*@source&.parent)
      end.flat_map do |path|
        Pathname.glob path
      end
    end
    attr_reader :name, :params

    def level
      case
      when Vegetation   == @type then 0
      when Import       == @type then 1
      when ArcGISRaster == @type then 1
      when Feature      == @type then 2
      when Overlay      == @type then 3
      when Relief       == @type then 4
      when Grid         == @type then 5
      when Declination  == @type then 6
      when Control      == @type then 7
      end
    end

    def <=>(other)
      [ self, other ].map(&:level).inject(&:<=>)
    end

    def ==(other)
      Layer === other && self.name == other.name
    end

    def uptodate?
      mtimes = [ @source&.mtime, @map.mtime(filename) ]
      mtimes.all? && mtimes.inject(&:<)
    end
  end
end

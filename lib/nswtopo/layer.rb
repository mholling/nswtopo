require_relative 'layer/raster_import'
require_relative 'layer/raster'
require_relative 'layer/raster_render'
require_relative 'layer/mask_render'
require_relative 'layer/vector_render'
require_relative 'layer/vegetation'
require_relative 'layer/import'
require_relative 'layer/arcgis_raster'
require_relative 'layer/colour_mask'
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
    TYPES = Set[Vegetation, Import, ColourMask, ArcGISRaster, Feature, Contour, Spot, Overlay, Relief, Grid, Declination, Control, Labels]

    def initialize(name, map, params)
      params.delete("min-version").then do |creator_string|
        creator_string ? Version[creator_string] : VERSION
      rescue Version::Error
        raise "layer '%s' has unrecognised version: %s" % [name, creator_string]
      end.then do |min_version|
        raise "layer '%s' requires nswtopo %s, this version: %s" % [name, min_version, VERSION] unless min_version <= VERSION
      end

      @type = begin
        NSWTopo.const_get params["type"]
      rescue NameError, TypeError
      end

      raise "layer '%s' has unrecognised type: %s" % [name, params["type"].inspect] unless TYPES === @type
      extend @type

      @params = @type.const_defined?(:DEFAULTS) ? @type.const_get(:DEFAULTS).transform_keys(&:to_s).deep_merge(params) : params
      @name, @map, @source, @path, resolution, ppi = Layer.sanitise(name), map, @params.delete("source"), @params.delete("path"), @params.delete("resolution"), @params.delete("ppi")
      @mm_per_px = ppi ? 25.4 / ppi : resolution ? @map.to_mm(resolution) : nil

      @type.const_get(:CREATE).map(&:to_s).each do |attr|
        instance_variable_set ?@ + attr.tr_s(?-, ?_), @params.delete(attr)
      end if @type.const_defined?(:CREATE)
    end

    attr_reader :name, :params
    alias to_s name

    def level
      case
      when Import       == @type then 0
      when ArcGISRaster == @type then 0
      when Vegetation   == @type then 1
      when ColourMask   == @type then 2
      when Feature      == @type then 3
      when Contour      == @type then 3
      when Spot         == @type then 3
      when Overlay      == @type then 4
      when Relief       == @type then 5
      when Grid         == @type then 6
      when Declination  == @type then 7
      when Control      == @type then 8
      when Labels       == @type then 99
      end
    end

    def <=>(other)
      self.level <=> other.level
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

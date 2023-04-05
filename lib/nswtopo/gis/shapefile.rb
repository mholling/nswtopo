module NSWTopo
  module Shapefile
    class Source
      def self.===(path)
        OS.ogrinfo "-ro", "-so", path
        true
      rescue OS::Error
        false
      end

      def initialize(path)
        @path = path
      end
      attr_accessor :path

      def layer(**options)
        Layer.new self, **options
      end

      def only_layer
        name, *others = OS.ogrinfo("-ro", "-so", @path).scan(/^\w*\d+: (.*?)(?: \([\w\s]+\))?$/).flatten
        return nil if others.any?
        return name if name
        File.basename(@path, File.extname(@path)).tap do |name|
          OS.ogrinfo "-ro", "-so", @path, name
        end
      rescue OS::Error
      end

      def layer_info
        OS.ogrinfo("-ro", "-so", @path).scan(/^\w*\d+: (.*?)(?: \(([\w\s]+)\))?$/).sort_by(&:first).map do |name, geom_type|
          geom_type ? "#{name} (#{geom_type.delete(?\s)})" : name
        end
      end
    end

    class Layer
      NoLayerError = Class.new RuntimeError

      def initialize(source, layer: nil, where: nil, fields: nil, sql: nil, geometry: nil, projection: nil)
        @source, @layer, @where, @fields, @sql, @geometry, @projection = source, layer, where, fields, sql, geometry, projection
      end

      def features
        raise "can't specify both SQL and where clause" if @sql && @where
        raise "can't specify both SQL and layer name" if @sql && @layer
        raise "no layer name or SQL specified" unless @layer || @sql
        sql   = ["-sql", sql] if @sql
        where = ["-where", "(" << Array(@where).join(") AND (") << ")"] if @where
        srs   = ["-t_srs", @projection] if @projection
        spat  = ["-spat", *@geometry.bounds.transpose.flatten, "-spat_srs", @geometry.projection] if @geometry
        misc  = %w[-mapFieldType Date=Integer,DateTime=Integer -dim XY]
        json = OS.ogr2ogr *(sql || where), *srs, *spat, *misc, *%w[-f GeoJSON -lco RFC7946=NO /vsistdout/], @source.path, *@layer
        GeoJSON::Collection.load json, *@projection
      rescue OS::Error => error
        raise unless /Couldn't fetch requested layer (.*)!/ === error.message
        raise "no such layer: #{$1}"
      end

      def counts
        raise NoLayerError, "no layer name provided" unless @layer
        count = ?_ * @fields.map(&:size).max + "count"
        where = %Q[WHERE (%s)] % [*@where].join(") AND (") if @where
        field_list = %Q["%s"] % @fields.join('", "')
        sql = <<~SQL % [field_list, count, @layer, where, field_list]
          SELECT %s, count(*) AS "%s"
          FROM "%s"
          %s
          GROUP BY %s
        SQL
        json = OS.ogr2ogr *%w[-f GeoJSON -dialect sqlite -sql], sql, "/vsistdout/", @source.path
        JSON.parse(json)["features"].map do |feature|
          feature["properties"]
        end.map do |properties|
          [properties.slice(*@fields), properties[count]]
        end
      rescue OS::Error => error
        raise unless /no such column: (.*)$/ === error.message
        raise "invalid field: #{$1}"
      end

      def info
        raise NoLayerError, "no layer name provided" unless @layer
        info = OS.ogrinfo *%w[-ro -so -noextent], @source.path, @layer
        geom_type = info.match(/^Geometry: (.*)$/)&.[](1)&.delete(?\s)
        count = info.match(/^Feature Count: (\d+)$/)&.[](1)
        fields = info.scan(/^(.*): (.*?) \(\d+\.\d+\)$/).to_h
        wkt = info.each_line.slice_after(/^Layer SRS WKT:/).drop(1).first&.slice_before(/^\S/)&.first&.join
        epsg = OS.gdalsrsinfo("-o", "epsg", wkt)[/\d+/] if wkt and !wkt["unknown"]
        { name: @layer, geometry: geom_type, EPSG: epsg, features: count, fields: (fields unless fields.empty?) }.compact
      rescue OS::Error => error
        raise unless /Couldn't fetch requested layer (.*)!/ === error.message
        raise "no such layer: #{$1}"
      end
    end
  end
end

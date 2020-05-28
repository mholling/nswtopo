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

      def info
        OS.ogrinfo("-ro", "-so", @path).each_line.grep(/^\w*\d+: (.*)$/) do |info|
          [info, []]
        end
      end
    end

    class Layer
      NoLayerError = Class.new RuntimeError

      def initialize(source, layer: nil, where: nil, fields: nil, sql: nil, geometry: nil, projection: nil)
        @source, @layer, @where, @fields, @sql, @layer, @geometry, @projection = source, layer, where, fields, sql, layer, geometry, projection
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
        json = OS.ogr2ogr *(sql || where), *srs, *spat, *misc, *%w[-f GeoJSON -lco RFC7946=NO /vsistdout/], @source.path, @layer
        GeoJSON::Collection.load json, *@projection
      rescue OS::Error => error
        raise unless /Couldn't fetch requested layer (.*)!/ === error.message
        raise "no such layer: #{$1}"
      end

      def counts
        raise NoLayerError, "no layer name provided" unless @layer
        count = ?_ * @fields.map(&:size).max + "count"
        sql = <<~SQL % [@fields.join('", "'), count, @layer, @fields.join('", "')]
          SELECT "%s", count(*) AS "%s"
          FROM "%s"
          GROUP BY "%s"
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
        info = OS.ogrinfo *%w[-ro -so -nocount -noextent], @source.path, @layer
        geom_type = info.match(/^Geometry: (.*)$/)&.[](1)&.delete(?\s)
        fields = info.scan(/^(.*): (.*?) \(\d+\.\d+\)$/).to_h
        { name: @layer, geometry: geom_type, fields: (fields unless fields.empty?) }.compact
      rescue OS::Error => error
        raise unless /Couldn't fetch requested layer (.*)!/ === error.message
        raise "no such layer: #{$1}"
      end
    end
  end
end

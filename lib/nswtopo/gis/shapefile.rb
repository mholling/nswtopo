module NSWTopo
  class Shapefile
    Error = Class.new RuntimeError

    def self.===(path)
      OS.ogrinfo "-ro", "-so", path
      true
    rescue OS::Error
      false
    end

    def initialize(path)
      @path = path
    end

    def features(where: nil, sql: nil, layer: nil, geometry:, projection: nil)
      raise "can't specify both SQL and where clause" if sql && where
      raise "can't specify both SQL and layer name" if sql && layer
      sql   = ["-sql", sql] if sql
      where = ["-where", "(" << Array(where).join(") AND (") << ")"] if where
      srs   = ["-t_srs", projection] if projection
      spat  = ["-spat", *geometry.bounds.transpose.flatten, "-spat_srs", geometry.projection]
      misc  = %w[-mapFieldType Date=Integer,DateTime=Integer -dim XY]
      json = OS.ogr2ogr *(sql || where), *srs, *spat, *misc, *%w[-f GeoJSON -lco RFC7946=NO /vsistdout/], @path, *layer
      GeoJSON::Collection.load json, *projection
    end
  end
end

module NSWTopo
  module Shapefile
    Error = Class.new RuntimeError

    def self.===(path)
      OS.ogrinfo "-ro", "-so", path
      true
    rescue OS::Error
      false
    end

    def shapefile_layer(shapefile_path, where: nil, sql: nil, layer: nil, margin: {})
      raise "#{@source}: can't specify both SQL and where clause" if sql && where
      raise "#{@source}: can't specify both SQL and layer name" if sql && layer
      sql   = ["-sql", sql] if sql
      where = ["-where", "(" << Array(where).join(") AND (") << ")"] if where
      srs   = ["-t_srs", @map.projection]
      spat  = ["-spat", *@map.bounds(margin: margin).transpose.flatten, "-spat_srs", @map.projection]
      misc  = %w[-mapFieldType Date=Integer,DateTime=Integer -dim XY]
      json = OS.ogr2ogr *(sql || where), *srs, *spat, *misc, "-f", "GeoJSON", "-lco", "RFC7946=NO", "/vsistdout/", shapefile_path, *layer
      GeoJSON::Collection.load json, @map.projection
    end
  end
end

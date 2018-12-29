module NSWTopo
  module Shapefile
    Error = Class.new RuntimeError

    def self.===(string)
      Dir.chdir @source.parent do
        OS.ogrinfo "-ro", "-so", string
        true
      rescue OS::Error
        false
      end
    end

    def shapefile_layer(path, where: nil, layer: nil, margin: {})
      Dir.chdir @source.parent do
        path = Pathname(path)
        raise "TODO: shapefile reader not yet implemented"
      end
    end
  end
end


  #   def shapefile_features(source, options)
  #     Enumerator.new do |yielder|
  #       shape_path = Pathname.new(source["path"]).expand_path(@sourcedir)
  #       layer = options["name"]
  #       sql   = %Q[-sql "%s"] % options["sql"] if options["sql"]
  #       where = %Q[-where "%s"] % [ *options["where"] ].map { |clause| "(#{clause})" }.join(" AND ") if options["where"]
  #       srs   = %Q[-t_srs "#{CONFIG.map.projection}"]
  #       spat  = %Q[-spat #{CONFIG.map.bounds.transpose.flatten.join ?\s} -spat_srs "#{CONFIG.map.projection}"]
  #       Dir.mktmppath do |temp_dir|
  #         json_path = temp_dir + "data.json"
  #         %x[ogr2ogr #{sql || where} #{srs} #{spat} -f GeoJSON "#{json_path}" "#{shape_path}" #{layer unless sql} -mapFieldType Date=Integer,DateTime=Integer -dim XY]
  #         JSON.parse(json_path.read).fetch("features").each do |feature|
  #           next unless geometry = feature["geometry"]
  #           dimension = case geometry["type"]
  #           when "Polygon", "MultiPolygon" then 2
  #           when "LineString", "MultiLineString" then 1
  #           when "Point", "MultiPoint" then 0
  #           else raise BadLayerError.new("cannot process features of type #{geometry['type']}")
  #           end
  #           data = case geometry["type"]
  #           when "Polygon"         then geometry["coordinates"]
  #           when "MultiPolygon"    then geometry["coordinates"].flatten(1)
  #           when "LineString"      then [ geometry["coordinates"] ]
  #           when "MultiLineString" then geometry["coordinates"]
  #           when "Point"           then [ geometry["coordinates"] ]
  #           when "MultiPoint"      then geometry["coordinates"]
  #           else abort("geometry type #{geometry['type']} unimplemented")
  #           end
  #           attributes = feature["properties"]
  #           yielder << [ dimension, data, attributes ]
  #         end
  #       end
  #     end
  #   end

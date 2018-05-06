module NSWTopo
  class FeatureSource
    include VectorRenderer
    attr_reader :path
    
    def initialize(name, params)
      @name, @params = name, params
      @path = Pathname.pwd + "#{name}.json"
    end
    
    def shapefile_features(map, source, options)
      Enumerator.new do |yielder|
        shape_path = Pathname.new source["path"]
        projection = Projection.new %x[gdalsrsinfo -o proj4 "#{shape_path}"].gsub(/['"]+/, "").strip
        xmin, xmax, ymin, ymax = map.transform_bounds_to(projection).map(&:sort).flatten
        layer = options["name"]
        sql   = %Q[-sql "%s"] % options["sql"] if options["sql"]
        where = %Q[-where "%s"] % [ *options["where"] ].map { |clause| "(#{clause})" }.join(" AND ") if options["where"]
        srs   = %Q[-t_srs "#{map.projection}"]
        spat  = %Q[-spat #{xmin} #{ymin} #{xmax} #{ymax}]
        Dir.mktmppath do |temp_dir|
          json_path = temp_dir + "data.json"
          %x[ogr2ogr #{sql || where} #{srs} #{spat} -f GeoJSON "#{json_path}" "#{shape_path}" #{layer unless sql} -mapFieldType Date=Integer,DateTime=Integer -dim XY]
          JSON.parse(json_path.read).fetch("features").each do |feature|
            next unless geometry = feature["geometry"]
            dimension = case geometry["type"]
            when "Polygon", "MultiPolygon" then 2
            when "LineString", "MultiLineString" then 1
            when "Point", "MultiPoint" then 0
            else raise BadLayerError.new("cannot process features of type #{geometry['type']}")
            end
            data = case geometry["type"]
            when "Polygon"         then geometry["coordinates"]
            when "MultiPolygon"    then geometry["coordinates"].flatten(1)
            when "LineString"      then [ geometry["coordinates"] ]
            when "MultiLineString" then geometry["coordinates"]
            when "Point"           then [ geometry["coordinates"] ]
            when "MultiPoint"      then geometry["coordinates"]
            else abort("geometry type #{geometry['type']} unimplemented")
            end
            attributes = feature["properties"]
            yielder << [ dimension, data, attributes ]
          end
        end
      end
    end
    
    def arcgis_features(map, source, options)
      options["definition"] ||= "1 = 1" if options.delete "redefine"
      url = if URI.parse(source["url"]).path.split(?/).any?
        source["url"]
      else
        [ source["url"], source["instance"] || "arcgis", "rest", "services", *source["folder"], source["service"], source["type"] || "MapServer" ].join(?/)
      end
      uri = URI.parse "#{url}?f=json"
      service = ArcGIS.get_json uri, source["headers"]
      ring = (map.coord_corners << map.coord_corners.first).reverse
      if params["local-reprojection"] || source["local-reprojection"] || options["local-reprojection"]
        wkt  = service["spatialReference"]["wkt"]
        wkid = service["spatialReference"]["latestWkid"] || service["spatialReference"]["wkid"]
        projection = Projection.new wkt ? "ESRI::#{wkt}".gsub(?", '\"') : "epsg:#{wkid == 102100 ? 3857 : wkid}"
        geometry = { "rings" => [ map.projection.reproject_to(projection, ring) ] }.to_json
      else
        sr = { "wkt" => map.projection.wkt_esri }.to_json
        geometry = { "rings" => [ ring ] }.to_json
      end
      geometry_query = { "geometry" => geometry, "geometryType" => "esriGeometryPolygon" }
      options["id"] ||= service["layers"].find do |layer|
        layer["name"] == options["name"]
      end.fetch("id")
      layer_id = options["id"]
      uri = URI.parse "#{url}/#{layer_id}?f=json"
      max_record_count, fields, types, type_id_field, min_scale, max_scale = ArcGIS.get_json(uri, source["headers"]).values_at *%w[maxRecordCount fields types typeIdField minScale maxScale]
      fields = fields.map { |field| { field["name"] => field } }.inject({}, &:merge)
      oid_field_name = fields.values.find { |field| field["type"] == "esriFieldTypeOID" }.fetch("name", nil)
      oid_field_alias = fields.values.find { |field| field["type"] == "esriFieldTypeOID" }.fetch("alias", oid_field_name)
      names = fields.map { |name, field| { field["alias"] => name } }.inject({}, &:merge)
      types = types && types.map { |type| { type["id"] => type } }.inject(&:merge)
      type_field_name = type_id_field && fields.values.find { |field| field["alias"] == type_id_field }.fetch("name")
      pages = Enumerator.new do |yielder|
        if options["definition"] && !service["supportsDynamicLayers"]
          uri = URI.parse "#{url}/identify"
          index_attribute = options["page-by"] || source["page-by"] || oid_field_alias || "OBJECTID"
          scale = options["scale"]
          scale ||= max_scale.zero? ? min_scale.zero? ? map.scale : 2 * min_scale : (min_scale + max_scale) / 2
          pixels = map.wgs84_bounds.map do |bound|
            bound.reverse.inject(&:-) * 96.0 * 110000 / scale / 0.0254
          end.map(&:ceil)
          bounds = projection ? map.transform_bounds_to(projection) : map.bounds
          query = {
            "f" => "json",
            "layers" => "all:#{layer_id}",
            "tolerance" => 0,
            "mapExtent" => bounds.transpose.flatten.join(?,),
            "imageDisplay" => [ *pixels, 96 ].join(?,),
            "returnGeometry" => true,
          }
          query["sr"] = sr if sr
          query.merge! geometry_query
          paginate = nil
          indices = []
          loop do
            definitions = [ *options["definition"], *paginate ]
            definition = "(#{definitions.join ') AND ('})"
            paged_query = query.merge("layerDefs" => "#{layer_id}:1 = 0) OR (#{definition}")
            page = ArcGIS.post_json(uri, paged_query.to_query, source["headers"]).fetch("results", [])
            break unless page.any?
            yielder << page
            indices += page.map { |feature| feature["attributes"][index_attribute] }
            # paginate = "#{index_attribute} NOT IN (#{indices.join ?,})"
            paginate = "#{index_attribute} > #{indices.map(&:to_i).max}"
          end
        elsif options["page-by"] || source["page-by"]
          uri = URI.parse "#{url}/#{layer_id}/query"
          index_attribute = options["page-by"] || source["page-by"]
          per_page = [ *max_record_count, *options["per-page"], *source["per-page"], 500 ].min
          field_names = [ index_attribute, *type_field_name, *options["category"], *options["rotate"], *options["label"] ] & fields.keys
          paginate = nil
          indices = []
          loop do
            query = geometry_query.merge("f" => "json", "returnGeometry" => true, "outFields" => field_names.join(?,))
            query["inSR"] = query["outSR"] = sr if sr
            clauses = [ *options["where"], *paginate ]
            query["where"] = "(#{clauses.join ') AND ('})" if clauses.any?
            page = ArcGIS.post_json(uri, query.to_query, source["headers"]).fetch("features", [])
            break unless page.any?
            yielder << page
            indices += page.map { |feature| feature["attributes"][index_attribute] }
            # paginate = "#{index_attribute} NOT IN (#{indices.join ?,})"
            paginate = "#{index_attribute} > #{indices.map(&:to_i).max}"
          end
        else
          where = [ *options["where"] ].map { |clause| "(#{clause})" }.join(" AND ") if options["where"]
          per_page = [ *max_record_count, *options["per-page"], *source["per-page"], 500 ].min
          if options["definition"]
            definitions = [ *options["definition"] ]
            definition = "(#{definitions.join ') AND ('})"
            layer = { "source" => { "type" => "mapLayer", "mapLayerId" => layer_id }, "definitionExpression" => "1 = 0) OR (#{definition}" }.to_json
            resource = "dynamicLayer"
            base_query = { "f" => "json", "layer" => layer }
          else
            resource = layer_id
            base_query = { "f" => "json" }
          end
          uri = URI.parse "#{url}/#{resource}/query"
          query = base_query.merge(geometry_query).merge("returnIdsOnly" => true)
          query["inSR"] = sr if sr
          query["where"] = where if where
          field_names = [ *oid_field_name, *type_field_name, *options["category"], *options["rotate"], *options["label"] ] & fields.keys
          ArcGIS.post_json(uri, query.to_query, source["headers"]).fetch("objectIds").to_a.each_slice(per_page) do |object_ids|
            query = base_query.merge("objectIds" => object_ids.join(?,), "returnGeometry" => true, "outFields" => field_names.join(?,))
            query["outSR"] = sr if sr
            page = ArcGIS.post_json(uri, query.to_query, source["headers"]).fetch("features", [])
            yielder << page
          end
        end
      end
      Enumerator.new do |yielder|
        pages.each do |page|
          page.each do |feature|
            geometry = feature["geometry"]
            raise BadLayerError.new("feature contains no geometry") unless geometry
            dimension, key = [ 0, 0, 1, 2 ].zip(%w[x points paths rings]).find { |dimension, key| geometry.key? key }
            data = case key
            when "x"
              point = geometry.values_at("x", "y")
              [ projection ? map.reproject_from(projection, point) : point ]
            when "points"
              points = geometry[key]
              projection ? map.reproject_from(projection, points) : points
            when "paths", "rings"
              geometry[key].map do |points|
                projection ? map.reproject_from(projection, points) : points
              end
            end
            names_values = feature["attributes"].map do |name_or_alias, value|
              value = nil if %w[null Null NULL <null> <Null> <NULL>].include? value
              [ names.fetch(name_or_alias, name_or_alias), value ]
            end
            attributes = Hash[names_values]
            type = types && types[attributes[type_field_name]]
            attributes.each do |name, value|
              case
              when type_field_name == name # name is the type field name
                attributes[name] = type["name"] if type
              when values = type && type["domains"][name] && type["domains"][name]["codedValues"] # name is the subtype field name
                coded_value = values.find { |coded_value| coded_value["code"] == value }
                attributes[name] = coded_value["name"] if coded_value
              when values = fields[name] && fields[name]["domain"] && fields[name]["domain"]["codedValues"] # name is a coded value field name
                coded_value = values.find { |coded_value| coded_value["code"] == value }
                attributes[name] = coded_value["name"] if coded_value
              end
            end
            yielder << [ dimension, data, attributes ]
          end
        end
      end
    end
    
    def wfs_features(map, source, options)
      url = source["url"]
      type_name = options["name"]
      per_page = [ *options["per-page"], *source["per-page"], 500 ].min
      headers = source["headers"]
      base_query = { "service" => "wfs", "version" => "2.0.0" }
      
      query = base_query.merge("request" => "DescribeFeatureType", "typeName" => type_name).to_query
      xml = WFS.get_xml URI.parse("#{url}?#{query}"), headers
      namespace, type = xml.elements["xsd:schema/xsd:element[@name='#{type_name}']/@type"].value.split ?:
      names = xml.elements.each("xsd:schema/[@name='#{type}']//xsd:element[@name][starts-with(@type,'xsd:')]/@name").map(&:value)
      types = xml.elements.each("xsd:schema/[@name='#{type}']//xsd:element[@name][starts-with(@type,'xsd:')]/@type").map(&:value)
      methods = names.zip(types).map do |name, type|
        method = case type
        when *%w[xsd:float xsd:double xsd:decimal] then :to_f
        when *%w[xsd:int xsd:short]                then :to_i
        else                                            :to_s
        end
        { name => method }
      end.inject({}, &:merge)
      
      geometry_name = xml.elements["xsd:schema/[@name='#{type}']//xsd:element[@name][starts-with(@type,'gml:')]/@name"].value
      geometry_type = xml.elements["xsd:schema/[@name='#{type}']//xsd:element[@name][starts-with(@type,'gml:')]/@type"].value
      dimension = case geometry_type
      when *%w[gml:PointPropertyType gml:MultiPointPropertyType] then 0
      when *%w[gml:CurvePropertyType gml:MultiCurvePropertyType] then 1
      when *%w[gml:SurfacePropertyType gml:MultiSurfacePropertyType] then 2
      else raise BadLayerError.new "unsupported geometry type '#{geometry_type}'"
      end
      
      query = base_query.merge("request" => "GetCapabilities").to_query
      xml = WFS.get_xml URI.parse("#{url}?#{query}"), headers
      default_crs = xml.elements["wfs:WFS_Capabilities/FeatureTypeList/FeatureType[Name[text()='#{namespace}:#{type_name}']]/DefaultCRS"].text
      wkid = default_crs.match(/EPSG::(\d+)$/)[1]
      projection = Projection.new "epsg:#{wkid}"
      
      points = map.projection.reproject_to(projection, map.coord_corners)
      polygon = [ *points, points.first ].map { |corner| corner.reverse.join ?\s }.join ?,
      bounds_filter = "INTERSECTS(#{geometry_name},POLYGON((#{polygon})))"
      
      filters = [ bounds_filter, *options["filter"], *options["where"] ]
      names &= [ *options["category"], *options["rotate"], *options["label"] ]
      get_query = {
        "request" => "GetFeature",
        "typeNames" => type_name,
        "propertyName" => names.join(?,),
        "count" => per_page,
        "cql_filter" => "(#{filters.join ') AND ('})"
      }
      
      Enumerator.new do |yielder|
        index = 0
        loop do
          query = base_query.merge(get_query).merge("startIndex" => index).to_query
          xml = WFS.get_xml URI.parse("#{url}?#{query}"), headers
          xml.elements.each("wfs:FeatureCollection/wfs:member/#{namespace}:#{type_name}") do |member|
            elements = names.map do |name|
              member.elements["#{namespace}:#{name}"]
            end
            values = methods.values_at(*names).zip(elements).map do |method, element|
              element ? element.attributes["xsi:nil"] == "true" ? nil : element.text ? element.text.send(method) : "" : nil
            end
            attributes = Hash[names.zip values]
            data = case dimension
            when 0
              member.elements.each(".//gml:pos/text()").map(&:to_s).map do |string|
                string.split.map(&:to_f).reverse
              end
            when 1, 2
              member.elements.each(".//gml:posList/text()").map(&:to_s).map do |string|
                string.split.map(&:to_f).each_slice(2).map(&:reverse)
              end
            end.map do |point_or_points|
              map.reproject_from projection, point_or_points
            end
            yielder << [ dimension, data, attributes ]
          end.length == per_page || break
          index += per_page
        end
      end
    end
    
    def create(map)
      return if path.exist?
      
      puts "Downloading: #{name}"
      feature_hull = map.coord_corners(1.0)
      
      %w[host instance folder service cookie].map do |key|
        { key => params.delete(key) }
      end.inject(&:merge).tap do |default|
        params["sources"] = { "default" => default }
      end unless params["sources"]
      
      sources = params["sources"].map do |name, source|
        source["headers"] ||= {}
        if source["cookie"]
          cookies = HTTP.head(URI.parse source["cookie"]) do |response|
            response.get_fields('Set-Cookie').map { |string| string.split(?;).first }
          end
          source["headers"]["Cookie"] = cookies.join("; ") if cookies.any?
        end
        source["url"] ||= (source["https"] ? URI::HTTPS : URI::HTTP).build(:host => source["host"]).to_s
        source["headers"]["Referer"] ||= source["url"]
        source["headers"]["User-Agent"] ||= "Ruby/#{RUBY_VERSION}"
        { name => source }
      end.inject(&:merge)
      
      params["features"].inject([]) do |memo, (key, value)|
        case value
        when Array then memo + value.map { |val| [ key, val ] }
        else memo << [ key, value ]
        end
      end.map do |key, value|
        case value
        when Integer then [ key, { "id" => value } ]   # key is a sublayer name, value is a service layer name
        when String  then [ key, { "name" => value } ] # key is a sublayer name, value is a service layer ID
        when Hash    then [ key, value ]               # key is a sublayer name, value is layer options
        when nil
          case key
          when String then [ key, { "name" => key } ]  # key is a service layer name
          when Hash                                    # key is a service layer name with definition
            [ key.first.first, { "name" => key.first.first, "definition" => key.first.last } ]
          when Integer                                 # key is a service layer ID
            [ sources.values.first["service"]["layers"].find { |layer| layer["id"] == key }.fetch("name"), { "id" => key } ]
          end
        end
      end.reject do |sublayer, options|
        params["exclude"].include? sublayer
      end.group_by(&:first).map do |sublayer, options_group|
        [ sublayer, options_group.map(&:last) ]
      end.map do |sublayer, options_array|
        $stdout << "  #{sublayer}"
        features = []
        options_array.inject([]) do |memo, options|
          memo << [] unless memo.any? && options.delete("fallback")
          memo.last << (memo.last.last || {}).merge(options)
          memo
        end.each do |fallbacks|
          fallbacks.inject(nil) do |error, options|
            substitutions = [ *options.delete("category") ].map do |category_or_hash, hash|
              case category_or_hash
              when Hash then category_or_hash
              else { category_or_hash => hash || {} }
              end
            end.inject({}, &:merge)
            options["category"] = substitutions.keys
            source = sources[options["source"] || sources.keys.first]
            begin
              case source["protocol"]
              when "arcgis"     then    arcgis_features(map, source, options)
              when "wfs"        then       wfs_features(map, source, options)
              when "shapefile"  then shapefile_features(map, source, options)
              end
            rescue InternetError, ServerError => error
              next error
            end.each do |dimension, data, attributes|
              case dimension
              when 0 then data.clip_points! feature_hull
              when 1 then data.clip_lines!  feature_hull
              when 2 then data.clip_polys!  feature_hull
              end
              next if data.empty?
              categories = substitutions.map do |name, substitutes|
                value = attributes.fetch(name, name)
                substitutes.fetch(value, value).to_s.to_category
              end
              case attributes[options["rotate"]]
              when nil, 0, "0"
                categories << "no-angle"
              else
                categories << "angle"
                angle = case options["rotation-style"]
                when "arithmetic" then      attributes[options["rotate"]].to_f
                when "geographic" then 90 - attributes[options["rotate"]].to_f
                else                   90 - attributes[options["rotate"]].to_f
                end
              end if options["rotate"]
              features << { "dimension" => dimension, "data" => data, "categories" => categories }.tap do |feature|
                feature["label-only"] = options["label-only"] if options["label-only"]
                feature["angle"] = angle if angle
                [ *options["label"] ].map do |key|
                  attributes.fetch(key, key)
                end.tap do |labels|
                  feature["labels"] = labels unless labels.map(&:to_s).all?(&:empty?)
                end
              end
              $stdout << "\r  #{sublayer} (#{features.length} feature#{?s unless features.one?})"
            end
            break nil
          end.tap do |error|
            raise error if error
          end
        end
        puts
        { sublayer => features }
      end.inject(&:merge).tap do |layers|
        @layers = layers
        Dir.mktmppath do |temp_dir|
          json_path = temp_dir + "#{name}.json"
          json_path.open("w") { |file| file << layers.to_json }
          FileUtils.cp json_path, path
        end
      end
    end
    
    def layers
      @layers ||= begin
        raise BadLayerError.new("source file not found at #{path}") unless path.exist?
        JSON.parse(path.read).reject do |sublayer, features|
          params["exclude"].include? sublayer
        end
      end
    end
    
    def features(map)
      layers.map do |sublayer, features|
        [ sublayer, features.reject { |feature| feature["label-only"] } ]
      end.map do |sublayer, features|
        features.map do |feature|
          dimension, angle = feature.values_at "dimension", "angle"
          categories = feature["categories"].reject(&:empty?)
          points_or_lines = feature["data"].map do |coords|
            map.coords_to_mm coords
          end
          [ dimension, points_or_lines, categories, sublayer, *angle ]
        end
      end.flatten(1)
    end
    
    def labels(map)
      layers.map do |sublayer, features|
        features.select do |feature|
          feature.key?("labels")
        end.map do |feature|
          dimension, data, labels, categories = feature.values_at *%w[dimension data labels categories]
          [ dimension, data, labels, [ sublayer, *categories ], sublayer ]
        end
      end.flatten(1)
    end
  end
  
  class ArcGISVector < FeatureSource
    def initialize(*args)
      super(*args)
      params["sources"].each { |name, source| source["protocol"] = "arcgis" }
    end
  end
  
  class ShapefileSource < FeatureSource
    def initialize(*args)
      super(*args)
      params["sources"].each { |name, source| source["protocol"] = "shapefile" }
    end
  end
end

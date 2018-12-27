module NSWTopo
  class FeatureSource
    include Vector

    def features
      # need:
      # - multiple sources per layer
      # - fallback sources
      # - one or many categories
      # - attribute or fixed-values categories
      # - add angle/no-angle categories for points
      # - add size-category
      # - add rotation angle
    end

    def shapefile_features(source, options)
      Enumerator.new do |yielder|
        shape_path = Pathname.new(source["path"]).expand_path(@sourcedir)
        layer = options["name"]
        sql   = %Q[-sql "%s"] % options["sql"] if options["sql"]
        where = %Q[-where "%s"] % [ *options["where"] ].map { |clause| "(#{clause})" }.join(" AND ") if options["where"]
        srs   = %Q[-t_srs "#{CONFIG.map.projection}"]
        spat  = %Q[-spat #{CONFIG.map.bounds.transpose.flatten.join ?\s} -spat_srs "#{CONFIG.map.projection}"]
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

    def arcgis_features(source, options)
      max_record_count, fields, types, type_id_field, min_scale, max_scale = ArcGIS.get_json(uri, source["headers"]).values_at *%w[maxRecordCount fields types typeIdField minScale maxScale]
      fields = fields.map { |field| { field["name"] => field } }.inject({}, &:merge)
      names = fields.map { |name, field| { field["alias"] => name } }.inject({}, &:merge)
      types = types && types.map { |type| { type["id"] => type } }.inject(&:merge)
      type_field_name = type_id_field && fields.values.find { |field| field["alias"] == type_id_field }.fetch("name")
      pages = Enumerator.new do |yielder|
        if options["definition"] && !service["supportsDynamicLayers"]
        elsif options["page-by"] || source["page-by"]
        else
          where = [ *options["where"] ].map { |clause| "(#{clause})" }.join(" AND ") if options["where"]
          per_page = [ *max_record_count, *options["per-page"], *source["per-page"], 500 ].min
          if options["definition"]
          else
            resource = layer_id
            base_query = { "f" => "json" }
          end
          uri = URI.parse "#{url}/#{resource}/query"
          query = base_query.merge(geometry_query).merge("returnIdsOnly" => true)
          query["inSR"] = sr if sr
          query["where"] = where if where
          field_names = [ *oid_field_name, *type_field_name, *options["category"], *options["rotate"], *options["label"] ] & fields.keys
          ArcGIS.post_json(uri, URI.encode_www_form(query), source["headers"]).fetch("objectIds").to_a.each_slice(per_page) do |object_ids|
            query = base_query.merge("objectIds" => object_ids.join(?,), "returnGeometry" => true, "outFields" => field_names.join(?,))
            query["outSR"] = sr if sr
            page = ArcGIS.post_json(uri, URI.encode_www_form(query), source["headers"]).fetch("features", [])
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
              [ projection ? CONFIG.map.reproject_from(projection, point) : point ]
            when "points"
              points = geometry[key]
              projection ? CONFIG.map.reproject_from(projection, points) : points
            when "paths", "rings"
              geometry[key].map do |points|
                projection ? CONFIG.map.reproject_from(projection, points) : points
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

    def create
      return if path.exist?

      puts "Downloading: #{name}"
      feature_hull = CONFIG.map.coord_corners(1.0)

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
              when "arcgis"     then    arcgis_features(source, options)
              when "wfs"        then       wfs_features(source, options)
              when "shapefile"  then shapefile_features(source, options)
              end
            rescue InternetError, ServerError => error
              next error
            end.each do |dimension, data, attributes|
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
              options["size-category"].tap do |mm, max = 9|
                unit = 0.001 * (mm == true ? 5 : mm) * CONFIG.map.scale
                case dimension
                when 1
                  length = data.map(&:path_length).inject(0, &:+)
                  size = (Math::log2(length) - Math::log2(unit)).ceil rescue 0
                  categories << [ [ 0, size ].max, max ].min.to_s
                when 2
                  area = data.map(&:signed_area).inject(0, &:-)
                  size = (0.5 * Math::log2(area) - Math::log2(unit)).ceil rescue 0
                  categories << [ [ 0, size ].max, max ].min.to_s
                end
              end if options["size-category"]
              case dimension
              when 0 then data.clip_points! feature_hull
              when 1 then data.clip_lines!  feature_hull
              when 2 then data.clip_polys!  feature_hull
              end
              next if data.empty?
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

    def features
      layers.map do |sublayer, features|
        next [] if sublayer =~ /-labels$/
        features.reject do |feature|
          feature["label-only"]
        end.map do |feature|
          dimension, angle = feature.values_at "dimension", "angle"
          categories = feature["categories"].reject(&:empty?)
          points_or_lines = feature["data"].map do |coords|
            CONFIG.map.coords_to_mm coords
          end
          [ dimension, points_or_lines, categories, sublayer, *angle ]
        end
      end.flatten(1)
    end

    def labels
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

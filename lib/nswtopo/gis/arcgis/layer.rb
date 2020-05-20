module NSWTopo
  module ArcGIS
    class Layer
      EXCLUDED_TYPES = %w[esriFieldTypeGeometry esriFieldTypeDate esriFieldTypeBlob esriFieldTypeRaster esriFieldTypeXML].to_set

      def initialize(service, id: nil, layer: nil, where: nil, geometry: nil, fields: nil, launder: nil, truncate: nil, decode: nil, mixed: true)
        @service, @decode, @mixed = service, decode, mixed

        raise Error, "no ArcGIS layer name or url provided" unless layer || id
        @id = service["layers"].find do |info|
          layer ? String(layer) == info["name"] : Integer(id) == info["id"]
        end&.dig("id")
        raise Error, "no such ArcGIS layer: #{layer || id}" unless @id

        info = get_json "#{@id}"
        @name, @max_record_count, @fields, @geometry_type, capabilities = info.values_at *%w[name maxRecordCount fields geometryType capabilities]
        raise Error, "no query capability available for layer: #{@name}" unless capabilities =~ /Query|Data/

        [[%w[typeIdField], %w[subtypeField subtypeFieldName]], %w[types subtypes], %w[id code]].transpose.map do |name_keys, lookup_key, value_key|
          next info.values_at(*name_keys).compact.reject(&:empty?).first, info[lookup_key], value_key
        end.find do |name_or_alias, lookup, value_key|
          name_or_alias && lookup&.any?
        end&.tap do |name_or_alias, lookup, value_key|
          @type_field = @fields.find do |field|
            field.values_at("alias", "name").compact.include? name_or_alias
          end&.fetch("name")

          @type_values = lookup.map do |type|
            type.values_at value_key, "name"
          end.to_h

          @subtype_values = lookup.map do |type|
            type.values_at value_key, "domains"
          end.map do |code, domains|
            coded_values = domains.map do |name, domain|
              [name, domain["codedValues"]]
            end.select(&:last).map do |name, pairs|
              values = pairs.map do |pair|
                pair.values_at "code", "name"
              end.to_h
              [name, values]
            end.to_h
            [code, coded_values]
          end.to_h
        end

        @coded_values = @fields.map do |field|
          [field["name"], field.dig("domain", "codedValues")]
        end.select(&:last).map do |name, pairs|
          values = pairs.map do |pair|
            pair.values_at "code", "name"
          end.to_h
          [name, values]
        end.to_h

        fields ||= @fields.reject do |field|
          EXCLUDED_TYPES === field["type"]
        end.map do |field|
          field["name"]
        end

        @out_fields = fields.map do |name|
          @fields.find(-> { raise "invalid field name: #{name}" }) do |field|
            field.values_at("alias", "name").include? name
          end.fetch("name")
        end.join(?,)

        @rename = @fields.map do |field|
          field["name"]
        end.map do |name|
          next name, launder ? name.downcase.gsub(/[^\w]+/, ?_) : name
        end.map do |name, substitute|
          next name, truncate ? substitute.slice(0...truncate) : substitute
        end.partition do |name, substitute|
          name == substitute
        end.inject(&:+).inject(Hash[]) do |lookup, (name, substitute)|
          suffix, index, candidate = "_2", 3, substitute
          while lookup.key? candidate
            suffix, index, candidate = "_#{index}", index + 1, (Integer === launder ? substitute.slice(0, launder - suffix.length) : substitute) + suffix
            raise "can't launder field name #{name}" if Integer === launder && suffix.length >= launder
          end
          lookup.merge candidate => name
        end.invert

        query = { returnIdsOnly: true }
        query[:where] = "(" << Array(where).join(") AND (") << ")" if where

        case
        when geometry
          raise "polgyon geometry required" unless geometry.polygon?
          query[:geometry] = { rings: geometry.reproject_to(projection).coordinates.map(&:reverse) }.to_json
          query[:geometryType] = "esriGeometryPolygon"
        when where
        else
          oid_field = @fields.find do |field|
            field["type"] == "esriFieldTypeOID"
          end&.fetch("name")
          query[:where] = oid_field ? "#{oid_field} IS NOT NULL" : "1=1"
        end

        @object_ids = get_json("#{@id}/query", query)["objectIds"] || []
        @count = @object_ids.count
      end

      extend Forwardable
      delegate %i[get_json projection] => :@service
      attr_reader :count

      def pages(per_page: nil)
        Enumerator.new do |yielder|
          per_page, total = [*per_page, *@max_record_count, 500].min, @object_ids.length
          yielder << GeoJSON::Collection.new(projection: projection, name: @name) if @object_ids.none?

          while @object_ids.any?
            begin
              get_json "#{@id}/query", outFields: @out_fields, objectIds: @object_ids.take(per_page).join(?,)
            rescue Error
              (per_page /= 2) > 0 ? retry : raise
            end.fetch("features", []).map do |feature|
              next unless geometry = feature["geometry"]
              attributes = feature.fetch "attributes", {}

              attributes = attributes.map do |name, value|
                next @rename[name], case
                when %w[null Null NULL <null> <Null> <NULL>].include?(value)
                  nil
                when !@decode
                  value
                when @type_field == name
                  @type_values[value]
                when lookup = @subtype_values&.dig(attributes[@type_field], name)
                  lookup[value]
                when lookup = @coded_values.dig(name)
                  lookup[value]
                else value
                end
              end.to_h

              case @geometry_type
              when "esriGeometryPoint"
                point = geometry.values_at "x", "y"
                next unless point.all?
                next GeoJSON::Point.new point, attributes
              when "esriGeometryMultipoint"
                points = geometry["points"]
                next unless points&.any?
                next GeoJSON::MultiPoint.new points.transpose.take(2).transpose, attributes
              when "esriGeometryPolyline"
                raise Error, "ArcGIS curve geometries not supported" if geometry.key? "curvePaths"
                paths = geometry["paths"]
                next unless paths&.any?
                next GeoJSON::LineString.new paths[0], attributes if @mixed && paths.one?
                next GeoJSON::MultiLineString.new paths, attributes
              when "esriGeometryPolygon"
                raise Error, "ArcGIS curve geometries not supported" if geometry.key? "curveRings"
                rings = geometry["rings"]
                next unless rings&.any?
                rings.each(&:reverse!) unless rings[0].anticlockwise?
                polys = rings.slice_before(&:anticlockwise?)
                next GeoJSON::Polygon.new polys.first, attributes if @mixed && polys.one?
                next GeoJSON::MultiPolygon.new polys.entries, attributes
              else
                raise Error, "unsupported ArcGIS geometry type: #{@geometry_type}"
              end
            end.compact.tap do |features|
              yielder << GeoJSON::Collection.new(projection: projection, features: features, name: @name)
            end
            @object_ids.shift per_page
          end
        end
      end

      def features(**options, &block)
        pages(**options).inject do |collection, page|
          yield collection.count, self.count if block_given?
          collection.merge! page
        end
      end
    end
  end
end

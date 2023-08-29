module NSWTopo
  module ArcGIS
    module Query
      UniqueFieldError = Class.new RuntimeError

      def base_query(**options)
        case
        when @unique
          raise UniqueFieldError
        when @geometry
          raise "polgyon geometry required" unless @geometry.polygon?
          options[:geometry] = { rings: @geometry.reproject_to(projection).coordinates.map(&:reverse) }.to_json
          options[:geometryType] = "esriGeometryPolygon"
          options[:where] = join_clauses(*@where) if @where
        when @where
          options[:where] = join_clauses(*@where)
        else
          oid_field = @layer["fields"].find do |field|
            field["type"] == "esriFieldTypeOID"
          end&.fetch("name")
          options[:where] = oid_field ? "#{oid_field} IS NOT NULL" : "1=1"
        end
        options
      end

      def count
        @count ||= get_json("#{@id}/query", **base_query, returnCountOnly: true).dig("count")
      end

      def pages(per_page)
        objectids = get_json("#{@id}/query", **base_query, returnIdsOnly: true)["objectIds"] || []
        @count = objectids.count
        return [GeoJSON::Collection.new(projection: projection, name: @name)].each if @count.zero?

        @fields ||= @layer["fields"].select do |field|
          Layer::FIELD_TYPES === field["type"]
        end.map do |field|
          field["name"]
        end

        Enumerator.new do |yielder|
          out_fields = [*@fields, *extra_field].join ?,
          while objectids.any?
            begin
              get_json "#{@id}/query", outFields: out_fields, objectIds: objectids.take(per_page).join(?,)
            rescue Connection::Error
              (per_page /= 2) > 0 ? retry : raise
            end.fetch("features", []).filter_map do |feature|
              next unless geometry = feature["geometry"]
              properties = feature.fetch("attributes", {})

              case @geometry_type
              when "esriGeometryPoint"
                point = geometry.values_at "x", "y"
                next unless point.all?
                next GeoJSON::Point[point, properties]
              when "esriGeometryMultipoint"
                points = geometry["points"]
                next unless points&.any?
                next GeoJSON::MultiPoint[points.transpose.take(2).transpose, properties]
              when "esriGeometryPolyline"
                raise "ArcGIS curve geometries not supported" if geometry.key? "curvePaths"
                paths = geometry["paths"]
                next unless paths&.any?
                next GeoJSON::LineString[paths[0], properties] if @mixed && paths.one?
                next GeoJSON::MultiLineString[paths, properties]
              when "esriGeometryPolygon"
                raise "ArcGIS curve geometries not supported" if geometry.key? "curveRings"
                rings = geometry["rings"]
                next unless rings&.any?
                polys = GeoJSON::MultiLineString[rings.map(&:reverse), properties].to_multipolygon
                next @mixed && polys.one? ? polys.first : polys
              else
                raise "unsupported ArcGIS geometry type: #{@geometry_type}"
              end
            end.tap do |features|
              yielder << GeoJSON::Collection.new(projection: projection, features: features, name: @name)
            end
            objectids.shift per_page
          end
        end
      end
    end
  end
end

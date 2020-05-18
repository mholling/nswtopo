require_relative 'arcgis_server/connection'

module NSWTopo
  module ArcGISServer
    Error = Class.new RuntimeError
    ERRORS = [Timeout::Error, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EINVAL, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError]
    SERVICE = /^(?:MapServer|FeatureServer|ImageServer)$/

    def self.check_uri(url)
      uri = URI.parse url
      return unless URI::HTTP === uri
      return unless uri.path
      instance, (id, *) = uri.path.split(?/).slice_after(SERVICE).take(2)
      return unless SERVICE === instance&.last
      return unless !id || id =~ /^\d+$/
      return uri, instance.join(?/), id
    rescue URI::Error
    end

    def self.===(string)
      uri, service_path, id = check_uri string
      uri != nil
    end

    def self.start(url, &block)
      uri, service_path, id = check_uri url
      raise "invalid ArcGIS server URL: %s" % url unless uri
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 600) do |http|
        connection = Connection.new http, service_path
        service = connection.get_json
        projection = case
        when wkt  = service.dig("spatialReference", "wkt") then Projection.new(wkt)
        when wkid = service.dig("spatialReference", "latestWkid") then Projection.new("EPSG:#{wkid}")
        when wkid = service.dig("spatialReference", "wkid") then Projection.new("EPSG:#{wkid == 102100 ? 3857 : wkid}")
        else raise Error, "no spatial reference found: #{uri}"
        end
        yield connection, service, projection, *id
      end
    rescue *ERRORS => error
      raise Error, error.message
    end

    def arcgis_pages(url, where: nil, layer: nil, per_page: nil, geometry: nil, decode: nil, fields: nil, mixed: true, launder: nil, &block)
      Enumerator.new do |yielder|
        ArcGISServer.start url do |connection, service, projection, id|
          id = service["layers"].find do |info|
            layer.to_s == info["name"]
          end&.dig("id") if layer
          id ? nil : layer ? raise("no such ArcGIS layer: %s" % layer) : raise("not an ArcGIS layer url: %s" % url)

          layer = connection.get_json id.to_s
          max_record_count, layer_fields, types, type_id_field, geometry_type, capabilities, layer_name = layer.values_at "maxRecordCount", "fields", "types", "typeIdField", "geometryType", "capabilities", "name"
          raise Error, "no query capability available: #{url}" unless capabilities =~ /Query|Data/

          out_fields = fields.map do |name|
            layer_fields.find(-> { raise "invalid field name: #{name}" }) do |field|
              field.values_at("alias", "name").include? name
            end.fetch("name")
          end.join(?,) if fields

          launder = layer_fields.map do |field|
            next field["name"], case launder
            when Integer then field["name"].downcase.gsub(/[^\w]+/, ?_).slice(0...launder)
            when true then    field["name"].downcase.gsub(/[^\w]+/, ?_)
            else              field["name"]
            end
          end.partition do |name, truncated|
            name == truncated
          end.inject(&:+).inject(Hash[]) do |lookup, (name, truncated)|
            suffix, index, candidate = "_2", 3, truncated
            while lookup.key? candidate
              suffix, index, candidate = "_#{index}", index + 1, (Integer === launder ? truncated.slice(0, launder - suffix.length) : truncated) + suffix
              raise "can't launder field name #{name}" if Integer === launder && suffix.length >= launder
            end
            lookup.merge candidate => name
          end.invert

          if type_id_field && !type_id_field.empty? && types
            type_id_field = layer_fields.find do |field|
              field.values_at("alias", "name").include? type_id_field
            end&.fetch("name")
            type_values = types.map do |type|
              type.values_at "id", "name"
            end.to_h
            subtype_coded_values = types.map do |type|
              type.values_at "id", "domains"
            end.map do |id, domains|
              coded_values = domains.map do |name, domain|
                [name, domain["codedValues"]]
              end.select(&:last).map do |name, pairs|
                values = pairs.map do |pair|
                  pair.values_at "code", "name"
                end.to_h
                [name, values]
              end.to_h
              [id, coded_values]
            end.to_h
          end

          coded_values = layer_fields.map do |field|
            [field["name"], field.dig("domain", "codedValues")]
          end.select(&:last).map do |name, pairs|
            values = pairs.map do |pair|
              pair.values_at "code", "name"
            end.to_h
            [name, values]
          end.to_h

          query = { returnIdsOnly: true }
          query[:where] = Array(where).map do |clause|
            "(#{clause})"
          end.join(" AND ") if where

          case
          when geometry
            raise "polgyon geometry required" unless geometry.polygon?
            query[:geometry] = { rings: geometry.reproject_to(projection).coordinates.map(&:reverse) }.to_json
            query[:geometryType] = "esriGeometryPolygon"
          when where
          else
            oid_field = layer_fields.find do |field|
              field["type"] == "esriFieldTypeOID"
            end&.fetch("name")
            query[:where] = oid_field ? "#{oid_field} IS NOT NULL" : "1=1"
          end

          query_path = "#{id}/query"
          object_ids = connection.get_json(query_path, query)["objectIds"] || []
          per_page, total = [*per_page, *max_record_count, 500].min, object_ids.length

          yielder << GeoJSON::Collection.new(projection: projection, name: layer_name) if object_ids.none?
          while object_ids.any?
            yield total - object_ids.length, total if block_given?
            begin
              connection.get_json query_path, outFields: out_fields || ?*, objectIds: object_ids.take(per_page).join(?,)
            rescue *ERRORS, Error
              (per_page /= 2) > 0 ? retry : raise
            end.fetch("features", []).map do |feature|
              next unless geometry = feature["geometry"]
              attributes = feature.fetch "attributes", {}

              values = attributes.map do |name, value|
                case
                when %w[null Null NULL <null> <Null> <NULL>].include?(value)
                  nil
                when !decode
                  value
                when type_id_field == name
                  type_values[value]
                when lookup = subtype_coded_values&.dig(attributes[type_id_field], name)
                  lookup[value]
                when lookup = coded_values.dig(name)
                  lookup[value]
                else value
                end
              end
              attributes = launder.values_at(*attributes.keys).zip(values).to_h

              case geometry_type
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
                next GeoJSON::LineString.new paths[0], attributes if mixed && paths.one?
                next GeoJSON::MultiLineString.new paths, attributes
              when "esriGeometryPolygon"
                raise Error, "ArcGIS curve geometries not supported" if geometry.key? "curveRings"
                rings = geometry["rings"]
                next unless rings&.any?
                rings.each(&:reverse!) unless rings[0].anticlockwise?
                polys = rings.slice_before(&:anticlockwise?)
                next GeoJSON::Polygon.new polys.first, attributes if mixed && polys.one?
                next GeoJSON::MultiPolygon.new polys.entries, attributes
              else
                raise Error, "unsupported ArcGIS geometry type: #{geometry_type}"
              end
            end.compact.tap do |features|
              yielder << GeoJSON::Collection.new(projection: projection, features: features, name: layer_name)
            end
            object_ids.shift per_page
          end
          yield total, total if block_given?
        end
      end
    end

    def arcgis_layer(url, **options, &block)
      arcgis_pages(url, **options, &block).inject(&:merge!)
    end
  end
end

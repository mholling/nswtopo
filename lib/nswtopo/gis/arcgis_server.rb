require_relative 'arcgis_server/connection'

module NSWTopo
  module ArcGISServer
    Error = Class.new RuntimeError
    ERRORS = [Timeout::Error, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EINVAL, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError]
    SERVICE = /^(?:MapServer|FeatureServer|ImageServer)$/

    def self.check_uri(url)
      uri = URI.parse url
      return unless URI::HTTP === uri
      instance, (id, *) = uri.path.split(?/).slice_after(SERVICE).take(2)
      return unless instance.last =~ SERVICE
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

    def arcgis_layer(url, where: nil, layer: nil, per_page: nil, margin: {})
      ArcGISServer.start url do |connection, service, projection, id|
        id = service["layers"].find do |info|
          layer.to_s == info["name"]
        end&.dig("id") if layer
        id ? nil : layer ? raise("no such ArcGIS layer: %s" % layer) : raise("not an ArcGIS layer url: %s" % url)

        layer = connection.get_json id.to_s
        query_path = "#{id}/query"
        max_record_count, fields, types, type_id_field, geometry_type, capabilities = layer.values_at "maxRecordCount", "fields", "types", "typeIdField", "geometryType", "capabilities"
        raise Error, "no query capability available: #{url}" unless capabilities =~ /Query|Data/

        if type_id_field && types
          type_id_field = fields.find do |field|
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

        coded_values = fields.map do |field|
          [field["name"], field.dig("domain", "codedValues")]
        end.select(&:last).map do |name, pairs|
          values = pairs.map do |pair|
            pair.values_at "code", "name"
          end.to_h
          [name, values]
        end.to_h

        geometry = { rings: @map.bounding_box(margin).reproject_to(projection).coordinates.map(&:reverse) }.to_json
        where = Array(where).map { |clause| "(#{clause})"}.join " AND "
        query = { geometry: geometry, geometryType: "esriGeometryPolygon", returnIdsOnly: true, where: where }

        object_ids = connection.get_json(query_path, query)["objectIds"]
        next GeoJSON::Collection.new projection unless object_ids

        features = Enumerator.new do |yielder|
          per_page, total = [*per_page, *max_record_count, 500].min, object_ids.length
          while object_ids.any?
            yield total - object_ids.length, total if block_given? && total > 0
            yielder << begin
              connection.get_json query_path, outFields: ?*, objectIds: object_ids.take(per_page).join(?,)
            rescue Error => error
              (per_page /= 2) > 0 ? retry : raise(error)
            end
            object_ids.shift per_page
          end
        end.inject [] do |features, page|
          features += page["features"]
        end.map do |feature|
          next unless geometry = feature["geometry"]
          attributes = feature.fetch "attributes", {}

          values = attributes.map do |name, value|
            case
            when type_id_field == name
              type_values[value]
            when decode = subtype_coded_values&.dig(attributes[type_id_field], name)
              decode[value]
            when decode = coded_values.dig(name)
              decode[value]
            when %w[null Null NULL <null> <Null> <NULL>].include?(value)
              nil
            else value
            end
          end
          attributes = attributes.keys.zip(values).to_h

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
            next GeoJSON::LineString.new paths[0], attributes if paths.one?
            next GeoJSON::MultiLineString.new paths, attributes
          when "esriGeometryPolygon"
            raise Error, "ArcGIS curve geometries not supported" if geometry.key? "curveRings"
            rings = geometry["rings"]
            next unless rings&.any?
            rings.each(&:reverse!) unless rings[0].anticlockwise?
            next GeoJSON::Polygon.new rings, attributes if rings.one?
            next GeoJSON::MultiPolygon.new rings.slice_before(&:anticlockwise?).to_a, attributes
          else
            raise Error, "unsupported ArcGIS geometry type: #{geometry_type}"
          end
        end.compact

        GeoJSON::Collection.new projection, features
      end
    end
  end
end

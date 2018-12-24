module NSWTopo
  module ArcGISServer
    Error = Class.new RuntimeError
    SERVICE = /^(?:MapServer|FeatureServer|ImageServer)$/

    class Connection
      Error = Class.new RuntimeError

      def initialize(http, path)
        @http, @path, @headers = http, path, { "User-Agent" => "Ruby/#{RUBY_VERSION}", "Referer" => "%s://%s" % [ http.use_ssl? ? "https" : "http", http.address ] }
        http.max_retries = 0
      end

      def repeatedly_request(request, intervals = nil)
        intervals ||= 5.times.map(&1.4142.method(:**))
        response = @http.request(request)
        response.error! unless Net::HTTPSuccess === response
        yield response
      rescue Timeout::Error, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EINVAL, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError, Error => error
        interval = intervals.shift
        interval ? sleep(interval) : raise(Error, error.message)
        retry
      end

      def get(relative_path, **query, &block)
        path = Pathname(@path).join(relative_path).to_s
        path << ?? << URI.encode_www_form(query) unless query.empty?
        request = Net::HTTP::Get.new(path, @headers)
        repeatedly_request(request, &block)
      end

      def post(relative_path, **query, &block)
        path = Pathname(@path).join(relative_path).to_s
        request = Net::HTTP::Post.new(path, @headers)
        request.body = URI.encode_www_form(query)
        repeatedly_request(request, &block)
      end

      def process_json(response)
        JSON.parse(response.body).tap do |result|
          raise Error, result["error"].values_at("message", "details").compact.join(?\n) if result["error"]
        end
      rescue JSON::ParserError
        raise Error, "unexpected ArcGIS response format"
      end

      def get_json(relative_path = "", **query)
        get relative_path, query.merge(f: "json"), &method(:process_json)
      end

      def post_json(relative_path = "", **query)
        post relative_path, query.merge(f: "json"), &method(:process_json)
      end
    end

    def self.start(uri, &block)
      instance, (layer_id, *) = uri.path.split(?/).slice_after(SERVICE).take(2)
      raise Error, "invalid ArcGIS service URL: #{uri}" unless SERVICE === instance.last
      use_ssl = uri.scheme == "https"
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 600) do |http|
        connection = Connection.new http, instance.join(?/)
        service = connection.get_json
        projection = case
        when wkt  = service.dig("spatialReference", "wkt") then Projection.new(wkt)
        when wkid = service.dig("spatialReference", "latestWkid") then Projection.new("EPSG:#{wkid}")
        when wkid = service.dig("spatialReference", "wkid") then Projection.new("EPSG:#{wkid == 102100 ? 3857 : wkid}")
        else raise Error, "no spatial reference found: #{uri}"
        end
        yield connection, service, projection, *layer_id
      end
    end

    def get_layer(url, where: nil, margin: {}, per_page: nil)
      ArcGISServer.start URI.parse(url) do |connection, service, projection, layer_id|
        layer = connection.get_json layer_id
        query_path = "#{layer_id}/query"
        max_record_count, fields, types, type_id_field, geometry_type, capabilities = layer.values_at "maxRecordCount", "fields", "types", "typeIdField", "geometryType", "capabilities"

        raise Error, "invalid ArcGIS layer URL: #{url}" unless /^\d+$/ === layer_id
        raise Error, "no query capability available: #{url}" unless /Query|Data/ === capabilities

        if type_id_field && types
          type_id_field = fields.find do |field|
            field.values_at("alias", "name").include? type_id_field
          end&.fetch("name")
          type_values = types.map do |type|
            type.values_at "id", "name"
          end.to_h
        end

        coded_values = fields.map do |field|
          [ field["name"], field.dig("domain", "codedValues") ]
        end.select(&:last).map do |name, coded_values|
          values = coded_values.map do |pair|
            pair.values_at "code", "name"
          end.to_h
          [ name, values ]
        end.to_h

        geometry = { rings: @map.bounding_box(margin).reproject_to(projection).coordinates.map(&:reverse) }.to_json
        where = [ *where ].map { |clause| "(#{clause})"}.join " AND "
        query = { geometry: geometry, geometryType: "esriGeometryPolygon", returnIdsOnly: true, where: where }

        object_ids = connection.get_json(query_path, query)["objectIds"]
        next GeoJSON::Collection.new projection unless object_ids

        features = Enumerator.new do |yielder|
          per_page, total = [ *per_page, *max_record_count, 500 ].min, object_ids.length
          while object_ids.any?
            yield total - object_ids.length, total if block_given? && total > 0
            yielder << begin
              connection.get_json query_path, outFields: ?*, objectIds: object_ids.take(per_page).join(?,)
            rescue Connection::Error => error
              (per_page /= 2) > 0 ? retry : raise(error)
            end
            object_ids.shift per_page
          end
        end.inject [] do |features, page|
          features += page["features"]
        end.map do |feature|
          next unless geometry = feature["geometry"]
          next unless attributes = feature["attributes"]

          attributes.each do |name, value|
            attributes[name] = case
            when type_id_field == name then type_values[value]
            when coded_values.key?(name) then coded_values[name][value]
            when /^(?:null|Null|NULL|<null>|<Null>|<NULL>)$/ === value then nil
            else value
            end
          end

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
            raise Error, "unsupported geometry type: #{geometry_type}"
          end
        end.compact

        GeoJSON::Collection.new projection, features
      end
    end
  end
end

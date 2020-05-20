module NSWTopo
  module ArcGIS
    Error = Class.new RuntimeError

    class Connection
      ERRORS = [Timeout::Error, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EINVAL, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError]

      def initialize(uri, service_path)
        @http = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 600)
        @service_path, @headers = service_path, { "User-Agent" => "Ruby/#{RUBY_VERSION}", "Referer" => "%s://%s" % [@http.use_ssl? ? "https" : "http", @http.address] }
        @http.max_retries = 0
      end

      def repeatedly_request(request)
        intervals ||= 5.times.map(&1.4142.method(:**))
        response = @http.request(request)
        response.error! unless Net::HTTPSuccess === response
        yield response
      rescue *ERRORS, Error => error
        interval = intervals.shift
        interval ? sleep(interval) : raise(Error, error.message)
        retry
      end

      def get(relative_path, **query, &block)
        path = Pathname(@service_path).join(relative_path).to_s
        path << ?? << URI.encode_www_form(query) unless query.empty?
        request = Net::HTTP::Get.new(path, @headers)
        repeatedly_request(request, &block)
      end

      def post(relative_path, **query, &block)
        path = Pathname(@service_path).join(relative_path).to_s
        request = Net::HTTP::Post.new(path, @headers)
        request.body = URI.encode_www_form(query)
        repeatedly_request(request, &block)
      end

      def process_json(response)
        JSON.parse(response.body).tap do |result|
          next unless error = result["error"]
          # raise Error, error.values_at("message", "details").compact.join(?\n)
          raise Error, error.values_at("message", "code").map(&:to_s).reject(&:empty?).first
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
  end
end
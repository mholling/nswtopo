module NSWTopo
  module HTTP
    def self.request(uri, req)
      intervals = [ 1, 2, 2, 4, 4, 8, 8 ]
      begin
        use_ssl = uri.scheme == "https"
        response = Net::HTTP.start(uri.host, uri.port, :use_ssl => use_ssl, :read_timeout => 600) do |http|
          http.request(req)
        end
        response.error! unless Net::HTTPSuccess === response
        yield response
      rescue Timeout::Error, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EINVAL, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError, NSWTopo::ServerError => e
        if intervals.any?
          sleep(intervals.shift) and retry
        else
          raise InternetError.new(e.message)
        end
      end
    end

    def self.get(uri, *args, &block)
      request uri, Net::HTTP::Get.new(uri.request_uri, *args), &block
    end

    def self.post(uri, body, *args, &block)
      req = Net::HTTP::Post.new(uri.request_uri, *args)
      req.body = body.to_s
      request uri, req, &block
    end
    
    def self.head(uri, *args, &block)
      request uri, Net::HTTP::Head.new(uri.request_uri, *args), &block
    end
  end
end

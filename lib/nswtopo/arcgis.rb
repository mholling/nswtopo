module NSWTopo
  module ArcGIS
    def self.get_json(uri, *args)
      HTTP.get(uri, *args) do |response|
        JSON.parse(response.body).tap do |result|
          raise ServerError.new(result["error"]["message"]) if result["error"]
        end
      end
    rescue JSON::ParserError
      raise ServerError.new "unexpected response format"
    end

    def self.post_json(uri, body, *args)
      HTTP.post(uri, body, *args) do |response|
        JSON.parse(response.body).tap do |result|
          if result["error"]
            message = result["error"]["message"]
            details = result["error"]["details"]
            raise ServerError.new [ *message, *details ].join(?\n)
          end
        end
      end
    rescue JSON::ParserError
      raise ServerError.new "unexpected response format"
    end
  end
end

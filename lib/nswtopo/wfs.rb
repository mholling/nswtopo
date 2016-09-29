module NSWTopo
  module WFS
    def self.get_xml(uri, *args)
      HTTP.get(uri, *args) do |response|
        case response.content_type
        when "text/xml", "application/xml"
          REXML::Document.new(response.body).tap do |xml|
            raise ServerError.new xml.elements["//ows:ExceptionText/text()"] if xml.elements["ows:ExceptionReport"]
          end
        else raise ServerError.new "unexpected response format"
        end
      end
    end
  end
end

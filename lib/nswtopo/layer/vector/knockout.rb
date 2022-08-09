module NSWTopo
  module Vector
    class Knockout
      def initialize(element, buffer)
        @buffer = Numeric === buffer ? buffer : Config["knockout"] || 0.3
        @use = REXML::Element.new("use")
        @use.add_attributes "href" => "#" + element.attributes["id"]
      end
      attr_reader :buffer, :use
    end
  end
end

module NSWTopo
  module Vector
    class Knockout
      def initialize(element, buffer)
        buffer = Config["knockout"] || 0.3 if buffer == true
        @buffer = Float(buffer)
        @href = "#" + element.attributes["id"]
      end
      attr_reader :buffer

      def use
        REXML::Element.new("use").tap { |use| use.add_attributes "href" => @href } 
      end
    end
  end
end

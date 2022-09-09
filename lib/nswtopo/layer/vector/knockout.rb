module NSWTopo
  module Vector
    class Knockout
      def initialize(element, buffer, blur = 0)
        buffer = Config["knockout"] || 0.3 if buffer == true
        @buffer, @blur = Float(buffer), Float(blur)
        @href = "#" + element.attributes["id"]
      end

      def params
        return @buffer, @blur
      end

      def use
        REXML::Element.new("use").tap { |use| use.add_attributes "href" => @href } 
      end
    end
  end
end

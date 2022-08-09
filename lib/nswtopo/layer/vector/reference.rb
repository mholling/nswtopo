module NSWTopo
  module Vector
    class Reference
      def initialize(element)
        @href = "#" + element.attributes["id"]
      end

      def use
        REXML::Element.new("use").tap do |use|
          use.add_attributes "href" => @href
        end
      end
    end

    Cutout = Class.new Reference
    Knockout = Class.new Reference
  end
end

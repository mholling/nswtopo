module NSWTopo
  module VectorRender
    class Knockout
      def initialize(element, buffer)
        @buffer = Labels::Label.knockout(buffer)
        @href = "#" + element.attributes["id"]
      end
      attr_reader :buffer

      def use
        REXML::Element.new("use").tap { |use| use.add_attributes "href" => @href } 
      end
    end
  end
end

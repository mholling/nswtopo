module NSWTopo
  module Labels
    class Label
      def initialize(collection, label_index, feature_index, barrier_count, priority, hulls, attributes, elements, along = nil, fixed = nil)
        @label_index, @feature_index, @indices = label_index, feature_index, [label_index, feature_index]
        @collection, @barrier_count, @priority, @hulls, @attributes, @elements, @along, @fixed = collection, barrier_count, priority, hulls, attributes, elements, along, fixed
        @ordinal = [@barrier_count, @priority]
        @conflicts = Set.new
      end

      extend Forwardable
      delegate %i[text dual layer_name] => :@collection
      delegate %i[[] dig] => :@attributes
      delegate %i[bounds] => :@hulls

      attr_reader :label_index, :feature_index, :indices
      attr_reader :barrier_count, :hulls, :elements, :along, :fixed, :conflicts
      attr_accessor :priority, :ordinal

      def point?
        @along.nil?
      end

      def barriers?
        @barrier_count > 0
      end

      def optional?
        @attributes["optional"]
      end

      def coexists_with?(other)
        Array(@attributes["coexist"]).include? other.layer_name
      end

      def <=>(other)
        self.ordinal <=> other.ordinal
      end

      alias hash object_id
      alias eql? equal?

      def overlaps?(other, buffer:)
        return false if self == other
        [self, other].map(&:hulls).map(&:explode).inject(&:product).any? do |ring1, ring2|
          ring1.convex_overlaps? ring2, buffer: buffer
        end
      end

      def self.overlaps(labels, &block)
        Enumerator.new do |yielder|
          next unless labels.any?(&block)
          index = RTree.load(labels, &:bounds)
          index.each do |bounds, label|
            next unless buffer = yield(label)
            index.search(bounds, buffer: buffer).with_object(label).select do |other, label|
              label.overlaps? other, buffer: buffer
            end.inject(yielder, &:<<)
          end
        end
      end
    end
  end
end

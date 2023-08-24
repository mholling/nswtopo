module NSWTopo
  module Labels
    class Label
      def initialize(collection, label_index, feature_index, barrier_count, priority, hulls, attributes, elements, along = nil, fixed = nil)
        @label_index, @feature_index, @indices = label_index, feature_index, [label_index, feature_index]
        @collection, @barrier_count, @priority, @hulls, @attributes, @elements, @along, @fixed = collection, barrier_count, priority, hulls, attributes, elements, along, fixed
        @ordinal = [@barrier_count, @priority]
        @conflicts = Set[]
        @hulls.each { |hull| hull.owner = self }
      end

      extend Forwardable
      delegate %i[text dual layer_name] => :@collection
      delegate %i[[] dig] => :@attributes

      attr_reader :label_index, :feature_index, :indices
      attr_reader :barrier_count, :hulls, :elements, :along, :fixed, :conflicts
      attr_accessor :priority, :ordinal

      def bounds
        @bounds ||= @hulls.inject(&:+).bounds
      end

      def hull
        @hull ||= Hull.new @hulls.inject(:+).dissolve_points
      end

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

      def self.overlaps(labels, group = labels, &block)
        return Set[] unless group.any?(&block)
        index = RTree.load(labels.flat_map(&:hulls), &:bounds)
        group.each.with_object Set[] do |label, overlaps|
          next unless buffer = yield(label)
          index.search(label.bounds, buffer: buffer).each do |other|
            next if label == other.owner
            next if overlaps === [label, other.owner]
            next if overlaps === [other.owner, label]
            next unless label.hulls.length < 3 || label.hull.overlaps?(other, buffer: buffer)
            next unless label.hulls.any? do |hull|
              hull.overlaps? other, buffer: buffer
            end
            overlaps << [label, other.owner]
          end
        end
      end
    end
  end
end

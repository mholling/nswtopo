module NSWTopo
  module Labels
    class Label < ConvexHulls
      def initialize(baselines, collection, label_index, feature_index, priority, attributes, elements, along: nil, fixed: nil, &block)
        super baselines, 0.5 * attributes["font-size"]
        @label_index, @feature_index, @indices = label_index, feature_index, [label_index, feature_index]
        @collection, @priority, @attributes, @elements, @along, @fixed = collection, priority, attributes, elements, along, fixed
        @barrier_count = map(&block).inject(&:merge).size
        @ordinal = [@barrier_count, @priority]
        @conflicts = Set[]
        @hull = dissolve_points.convex_hull
      end

      extend Forwardable
      delegate %i[text dual layer_name] => :@collection
      delegate %i[[] dig] => :@attributes

      attr_reader :label_index, :feature_index, :indices
      attr_reader :barrier_count, :elements, :along, :fixed, :conflicts, :hull
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

      def self.overlaps(labels, group = labels, &block)
        return Set[] unless group.any?(&block)
        index = RTree.load(labels.flat_map(&:explode), &:bounds)
        group.each.with_object Set[] do |label, overlaps|
          next unless buffer = yield(label)
          index.search(label.bounds, buffer: buffer).each do |other|
            next if label == other[:source]
            next if overlaps === [label, other[:source]]
            next if overlaps === [other[:source], label]
            next unless label.coordinates.length < 3 || ConvexHulls.overlap?(label.hull, other, buffer: buffer)
            next unless label.any? do |hull|
              ConvexHulls.overlap?(hull, other, buffer: buffer)
            end
            overlaps << [label, other[:source]]
          end
        end
      end
    end
  end
end

module NSWTopo
  module Labels
    class Label < ConvexHulls
      def self.knockout(value)
        Float(Numeric === value ? value : value ? Config.fetch("knockout", 0.3) : 0)
      end

      def initialize(baselines, feature, priority, elements, along: nil, fixed: nil, &block)
        super baselines, 0.5 * feature["font-size"] do
          @categories, @text, @dual, @layer_name, @label_index, @feature_index = feature.values_at(:categories, :text, :dual, :layer_name, :label_index, :feature_index)
          @indices = [@label_index, @feature_index]
          @priority, @elements, @along, @fixed = priority, elements, along, fixed
          @hull = dissolve_points.convex_hull
          @optional, @coexist, knockout = feature.values_at("optional", "coexist", "knockout")
          @barrier_count = each.with_object(Label.knockout(knockout)).map(&block).inject(&:merge).size
          @ordinal = [@barrier_count, @priority]
          @separation = feature.fetch("separation", {})
        end
      end

      attr_reader :categories, :text, :dual, :layer_name, :label_index, :feature_index, :indices
      attr_reader :priority, :elements, :along, :fixed, :hull, :barrier_count, :ordinal, :separation

      def point?
        @along.nil?
      end

      def barriers?
        @barrier_count > 0
      end

      def optional?
        @optional
      end

      def coexists_with?(other)
        Array(@coexist).include? other.layer_name
      end

      def <=>(other)
        self.ordinal <=> other.ordinal
      end

      def self.overlaps(labels, group = labels, &block)
        return Set[] unless group.any?(&block)
        index = RTree.load(labels.flat_map(&:explode), &:bounds)
        group.each.with_object Set[] do |label, overlaps|
          next unless buffer = yield(label)
          index.search(label.bounds, buffer).each do |other|
            next if label == other.source
            next if overlaps === [label, other.source]
            next if overlaps === [other.source, label]
            next unless label.length < 3 || ConvexHulls.overlap?(label.hull, other, buffer)
            next unless label.any? do |hull|
              ConvexHulls.overlap?(hull, other, buffer)
            end
            overlaps << [label, other.source]
          end
        end
      end
    end
  end
end

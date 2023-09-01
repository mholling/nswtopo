module NSWTopo
  module Labels
    class Label < ConvexHulls
      def self.knockout(value)
        Float(Numeric === value ? value : value ? Config.fetch("knockout", 0.3) : 0)
      end

      def initialize(baselines, feature, priority, elements, along: nil, fixed: nil, &block)
        super baselines, 0.5 * feature["font-size"] do
          @feature, @priority, @elements, @along, @fixed = feature, priority, elements, along, fixed
          knockout = Label.knockout feature["knockout"]
          @barrier_count = each.with_object(knockout).map(&block).inject(&:merge).size
          @ordinal = [@barrier_count, @priority]
          @hull = dissolve_points.convex_hull
        end
      end

      attr_reader :priority, :elements, :along, :fixed, :barrier_count, :ordinal, :hull

      extend Forwardable
      delegate %i[[] dig] => :@feature

      def text          = @feature[:text]
      def dual          = @feature[:dual]
      def layer_name    = @feature[:layer_name]
      def label_index   = @feature[:label_index]
      def feature_index = @feature[:feature_index]
      def indices       = @feature.values_at(:label_index, :feature_index)

      def point?
        @along.nil?
      end

      def barriers?
        @barrier_count > 0
      end

      def optional?
        @feature["optional"]
      end

      def coexists_with?(other)
        Array(@feature["coexist"]).include? other.layer_name
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
            next if label == other.source
            next if overlaps === [label, other.source]
            next if overlaps === [other.source, label]
            next unless label.length < 3 || ConvexHulls.overlap?(label.hull, other, buffer: buffer)
            next unless label.any? do |hull|
              ConvexHulls.overlap?(hull, other, buffer: buffer)
            end
            overlaps << [label, other.source]
          end
        end
      end
    end
  end
end

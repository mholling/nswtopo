require_relative 'labels/barrier'

module NSWTopo
  module Labels
    include Vector, Log
    CENTRELINE_FRACTION = 0.35
    DEFAULT_SAMPLE = 5
    INSET = 1

    PROPERTIES = %w[font-size font-family font-variant font-style font-weight letter-spacing word-spacing margin orientation position separation separation-along separation-same separation-all max-turn min-radius max-angle format categories optional sample line-height upcase shield curved coexist]
    TRANSFORMS = %w[reduce fallback offset buffer smooth remove-holes minimum-area minimum-hole minimum-length remove keep-largest trim]

    DEFAULTS = YAML.load <<~YAML
      knockout: true
      preserve: true
      stroke: none
      fill: black
      font-style: italic
      font-family: Arial, Helvetica, sans-serif
      font-size: 1.8
      line-height: 110%
      margin: 1.0
      max-turn: 60
      min-radius: 0
      max-angle: #{StraightSkeleton::DEFAULT_ROUNDING_ANGLE}
      sample: #{DEFAULT_SAMPLE}
    YAML

    DEBUG_PARAMS = YAML.load <<~YAML
      debug:
        dupe: ~
        fill: none
        opacity: 0.5
        knockout: false
      debug feature:
        stroke: "#6600ff"
        stroke-width: 0.2
        symbol:
          circle:
            r: 0.3
            stroke: none
            fill: "#6600ff"
      debug candidate:
        stroke: magenta
        stroke-width: 0.2
    YAML

    def barriers
      @barriers ||= []
    end

    def label_features
      @label_features ||= []
    end

    module LabelFeatures
      attr_accessor :text, :layer_name
    end

    extend Forwardable
    delegate :<< => :barriers

    def add(layer)
      category_params, base_params = layer.params.fetch("labels", {}).partition do |key, value|
        Hash === value
      end.map(&:to_h)
      collate = base_params.delete "collate"
      @params.store layer.name, base_params if base_params.any?
      category_params.each do |category, params|
        categories = Array(category).map do |category|
          [layer.name, category].join(?\s)
        end
        @params.store categories, params
      end

      feature_count = feature_total = 0
      layer.labeling_features.tap do |features|
        feature_total = features.length
      end.map(&:multi).group_by do |feature|
        Set[layer.name, *feature["category"]]
      end.each do |categories, features|
        transforms, attributes, point_attributes, line_attributes = [nil, nil, "point", "line"].map do |extra_category|
          categories | Set[*extra_category]
        end.map do |categories|
          params_for(categories).merge("categories" => categories)
        end.zip([TRANSFORMS, PROPERTIES, PROPERTIES, PROPERTIES]).map do |selected_params, keys|
          selected_params.slice *keys
        end

        features.map do |feature|
          log_update "collecting labels: %s: feature %i of %i" % [layer.name, feature_count += 1, feature_total]
          label = feature["label"]
          text = case
          when REXML::Element === label then label
          when attributes["format"] then attributes["format"] % label
          else Array(label).map(&:to_s).map(&:strip).join(?\s)
          end
          text.upcase! if String === text && attributes["upcase"]

          transforms.inject([feature]) do |features, (transform, (arg, *args))|
            next features unless arg
            opts, args = args.partition do |arg|
              Hash === arg
            end
            opts = opts.inject({}, &:merge).transform_keys(&:to_sym)
            features.flat_map do |feature|
              case transform
              when "reduce"
                case arg
                when "skeleton"
                  feature.respond_to?(arg) ? feature.send(arg) : feature
                when "centrelines"
                  feature.respond_to?(arg) ? feature.send(arg, **opts) : feature
                when "centrepoints"
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE) * @map.metres_per_mm
                  feature.respond_to?(arg) ? feature.send(arg, interval: interval, **opts) : feature
                when "centres"
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE) * @map.metres_per_mm
                  feature.respond_to?(arg) ? feature.send(arg, interval: interval, **opts) : feature
                when "centroids"
                  feature.respond_to?(arg) ? feature.send(arg) : feature
                when "samples"
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE) * @map.metres_per_mm
                  feature.respond_to?(arg) ? feature.send(arg, interval) : feature
                else
                  raise "unrecognised label transform: reduce: %s" % arg
                end

              when "fallback"
                case arg
                when "samples"
                  next feature unless feature.respond_to? arg
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE) * @map.metres_per_mm
                  [feature, *feature.send(arg, interval)]
                else
                  raise "unrecognised label transform: fallback: %s" % arg
                end

              when "offset", "buffer"
                next feature unless feature.respond_to? transform
                margins = [arg, *args].map { |value| Float(value) * @map.metres_per_mm }
                feature.send transform, *margins, **opts

              when "smooth"
                next feature unless feature.respond_to? transform
                margin = Float(arg) * @map.metres_per_mm
                max_turn = attributes["max-turn"] * Math::PI / 180
                feature.send transform, margin, cutoff_angle: max_turn, **opts

              when "minimum-area"
                area = Float(arg) * @map.metres_per_mm**2
                case feature
                when GeoJSON::MultiLineString
                  feature.coordinates = feature.coordinates.reject do |linestring|
                    linestring.first == linestring.last && linestring.signed_area.abs < area
                  end
                when GeoJSON::MultiPolygon
                  feature.coordinates = feature.coordinates.reject do |rings|
                    rings.sum(&:signed_area) < area
                  end
                end
                feature.empty? ? [] : feature

              when "minimum-length"
                next feature unless GeoJSON::MultiLineString === feature
                distance = Float(arg) * @map.metres_per_mm
                feature.coordinates = feature.coordinates.reject do |linestring|
                  linestring.path_length < distance
                end
                feature.empty? ? [] : feature

              when "minimum-hole", "remove-holes"
                area = Float(arg).abs * @map.metres_per_mm**2 unless true == arg
                feature.coordinates = feature.coordinates.map do |rings|
                  rings.reject do |ring|
                    area ? (-area...0) === ring.signed_area : ring.signed_area < 0
                  end
                end if GeoJSON::MultiPolygon === feature
                feature

              when "remove"
                remove = [arg, *args].any? do |value|
                  case value
                  when true    then true
                  when String  then text == value
                  when Regexp  then text =~ value
                  when Numeric then text == value.to_s
                  end
                end
                remove ? [] : feature

              when "keep-largest"
                case feature
                when GeoJSON::MultiLineString
                  feature.coordinates = [feature.explode.max_by(&:length).coordinates]
                when GeoJSON::MultiPolygon
                  feature.coordinates = [feature.explode.max_by(&:area).coordinates]
                end
                feature

              when "trim"
                next feature unless GeoJSON::MultiLineString === feature
                distance = Float(arg) * @map.metres_per_mm
                feature.coordinates = feature.coordinates.map do |linestring|
                  linestring.trim distance
                end.reject(&:empty?)
                feature.empty? ? [] : feature
              end
            end
          rescue ArgumentError
            raise "invalid label transform: %s: %s" % [transform, [arg, *args].join(?,)]
          end.each do |feature|
            feature.properties = case feature
            when GeoJSON::MultiPoint      then point_attributes
            when GeoJSON::MultiLineString then line_attributes
            when GeoJSON::MultiPolygon    then line_attributes
            end
          end.then do |features|
            GeoJSON::Collection.new(projection: @map.projection, features: features).explode.extend(LabelFeatures)
          end.tap do |collection|
            collection.text, collection.layer_name = text, layer.name
          end
        end.then do |collections|
          next collections unless collate
          collections.group_by(&:text).map do |text, collections|
            collections.inject(&:merge!)
          end
        end.each do |collection|
          label_features << collection
        end
      end
    end

    class Label
      def initialize(collection, label_index, feature_index, barrier_count, priority, hulls, attributes, elements, along = nil, fixed = nil)
        @label_index, @feature_index, @indices = label_index, feature_index, [label_index, feature_index]
        @collection, @barrier_count, @priority, @hulls, @attributes, @elements, @along, @fixed = collection, barrier_count, priority, hulls, attributes, elements, along, fixed
        @ordinal = [@barrier_count, @priority]
        @conflicts = Set.new
      end

      extend Forwardable
      delegate %i[text layer_name] => :@collection
      delegate :[] => :@attributes

      attr_reader :label_index, :feature_index, :indices
      attr_reader :hulls, :elements, :along, :fixed, :conflicts
      attr_accessor :priority, :ordinal

      def point?
        @along.nil?
      end

      def barriers?
        @barrier_count > 0
      end

      def optional?
        @attributes["optional"] && barriers?
      end

      def coexists_with?(other)
        Array(@attributes["coexist"]).include? other.layer_name
      end

      def <=>(other)
        self.ordinal <=> other.ordinal
      end

      alias hash object_id
      alias eql? equal?

      def bounds
        @hulls.flatten(1).transpose.map(&:minmax)
      end

      def self.overlaps(labels, buffer = 0)
        RTree.load(labels, &:bounds).overlaps(buffer).select do |pair|
          pair.map(&:hulls).inject(&:product).any? do |hulls|
            hulls.overlap?(buffer)
          end
        end
      end
    end

    def labelling_hull
      @labelling_hull ||= @map.bounding_box(mm: -INSET).coordinates.first.map(&to_mm)
    end

    def barrier_segments
      @barrier_segments ||= barriers.flat_map do |barrier|
        barrier.segments(&to_mm)
      end.then do |segments|
        RTree.load(segments, &:bounds)
      end
    end

    def point_candidates(collection, label_index, feature_index, feature)
      attributes  = feature.properties
      margin      = attributes["margin"]
      line_height = attributes["line-height"]
      font_size   = attributes["font-size"]

      point = feature.coordinates.then(&to_mm)
      lines = Font.in_two collection.text, attributes
      lines = [[collection.text, Font.glyph_length(collection.text, attributes)]] if lines.map(&:first).map(&:length).min == 1
      height = lines.map { font_size }.inject { |total| total + line_height }
      # if attributes["shield"]
      #   width += SHIELD_X * font_size
      #   height += SHIELD_Y * font_size
      # end

      [*attributes["position"] || "over"].map do |position|
        dx = position =~ /right$/ ? 1 : position =~ /left$/  ? -1 : 0
        dy = position =~ /^below/ ? 1 : position =~ /^above/ ? -1 : 0
        next dx, dy, dx * dy == 0 ? 1 : 0.6
      end.uniq.map.with_index do |(dx, dy, f), position_index|
        text_elements, hulls = lines.map.with_index do |(line, text_length), index|
          anchor = point.dup
          anchor[0] += dx * (f * margin + 0.5 * text_length)
          anchor[1] += dy * (f * margin + 0.5 * height)
          anchor[1] += (index - 0.5) * 0.5 * height unless lines.one?

          text_element = REXML::Element.new("text")
          text_element.add_attribute "transform", "translate(%s)" % POINT % anchor
          text_element.add_attribute "text-anchor", "middle"
          text_element.add_attribute "textLength", VALUE % text_length
          text_element.add_attribute "y", VALUE % (CENTRELINE_FRACTION * font_size)
          text_element.add_text line

          hull = [text_length, font_size].zip(anchor).map do |size, origin|
            [origin - 0.5 * size, origin + 0.5 * size]
          end.inject(&:product).values_at(0,2,3,1)

          next text_element, hull
        end.transpose

        next unless hulls.all? do |hull|
          labelling_hull.surrounds? hull
        end

        barrier_count = barrier_segments.search(hulls.flatten(1).transpose.map(&:minmax)).with_object Set[] do |segment, barriers|
          next if barriers === segment.barrier
          hulls.any? do |hull|
            barriers << segment.barrier if segment.conflicts_with? hull
          end
        end.size
        priority = [position_index, feature_index]
        Label.new collection, label_index, feature_index, barrier_count, priority, hulls, attributes, text_elements
      end.compact.reject(&:optional?).tap do |candidates|
        candidates.combination(2).each do |candidate1, candidate2|
          candidate1.conflicts << candidate2
          candidate2.conflicts << candidate1
        end
      end
    end

    def line_string_candidates(collection, label_index, feature_index, feature)
      closed = feature.coordinates.first == feature.coordinates.last
      pairs = closed ? :ring : :segments
      data = feature.coordinates.map(&to_mm)

      attributes  = feature.properties
      orientation = attributes["orientation"]
      max_turn    = attributes["max-turn"] * Math::PI / 180
      min_radius  = attributes["min-radius"]
      max_angle   = attributes["max-angle"] * Math::PI / 180
      curved      = attributes["curved"]
      sample      = attributes["sample"]
      separation  = attributes["separation-along"]
      font_size   = attributes["font-size"]

      text_length = case collection.text
      when REXML::Element then data.path_length
      when String then Font.glyph_length collection.text, attributes
      end

      points = data.segments.inject([]) do |memo, segment|
        distance = segment.distance
        case
        when REXML::Element === collection.text
          memo << segment[0]
        when curved && distance >= text_length
          memo << segment[0]
        else
          steps = (distance / sample).ceil
          memo += steps.times.map do |step|
            segment.along(step.to_f / steps)
          end
        end
      end
      points << data.last unless closed

      segments = points.send(pairs)
      vectors = segments.map(&:diff)
      distances = vectors.map(&:norm)

      cumulative = distances.inject([0]) do |memo, distance|
        memo << memo.last + distance
      end
      total = closed ? cumulative.pop : cumulative.last

      angles = vectors.map(&:normalised).send(pairs).map do |directions|
        Math.atan2 directions.inject(&:cross), directions.inject(&:dot)
      end
      closed ? angles.rotate!(-1) : angles.unshift(0).push(0)

      curvatures = segments.send(pairs).map do |(p0, p1), (_, p2)|
        sides = [[p0, p1], [p1, p2], [p2, p0]].map(&:distance)
        semiperimeter = 0.5 * sides.inject(&:+)
        diffs = sides.map { |side| semiperimeter - side }
        area_squared = [semiperimeter * diffs.inject(&:*), 0].max
        4 * Math::sqrt(area_squared) / sides.inject(&:*)
      end
      closed ? curvatures.rotate!(-1) : curvatures.unshift(0).push(0)

      dont_use = angles.zip(curvatures).map do |angle, curvature|
        angle.abs > max_angle || min_radius * curvature > 1
      end

      squared_angles = angles.map { |angle| angle * angle }

      overlaps = Hash.new do |overlaps, label_segment|
        bounds = label_segment.transpose.map(&:minmax).map do |min, max|
          [min - 0.5 * font_size, max + 0.5 * font_size]
        end
        overlaps[label_segment] = barrier_segments.search(bounds).select do |barrier_segment|
          barrier_segment.conflicts_with?(label_segment, 0.5 * font_size)
        end.inject Set[] do |barriers, segment|
          barriers.add segment.barrier
        end
      end

      Enumerator.new do |yielder|
        indices, distance, bad_indices, angle_integral = [0], 0, [], []
        loop do
          while distance < text_length
            break true if closed ? indices.many? && indices.last == indices.first : indices.last == points.length - 1
            unless indices.one?
              bad_indices << dont_use[indices.last]
              angle_integral << (angle_integral.last || 0) + angles[indices.last]
            end
            distance += distances[indices.last]
            indices << (indices.last + 1) % points.length
          end && break

          while distance >= text_length
            case
            when indices.length == 2 && curved
            when indices.length == 2 then yielder << indices.dup
            when distance - distances[indices.first] >= text_length
            when bad_indices.any?
            when angle_integral.max - angle_integral.min > max_turn
            else yielder << indices.dup
            end
            angle_integral.shift
            bad_indices.shift
            distance -= distances[indices.first]
            indices.shift
            break true if indices.first == (closed ? 0 : points.length - 1)
          end && break
        end if points.many?
      end.map do |indices|
        start, stop = cumulative.values_at(*indices)
        along = (start + 0.5 * (stop - start) % total) % total
        total_squared_curvature = squared_angles.values_at(*indices[1...-1]).inject(0, &:+)
        baseline = points.values_at(*indices).crop(text_length)

        barrier_count = baseline.segments.inject Set[] do |barriers, segment|
          barriers.merge overlaps[segment]
        end.size
        priority = [total_squared_curvature, (total - 2 * along).abs / total.to_f]

        baseline.reverse! unless case orientation
        when "uphill", "anticlockwise" then true
        when "downhill", "clockwise" then false
        else baseline.values_at(0, -1).map(&:first).inject(&:<=)
        end

        hull = GeoJSON::LineString.new(baseline).multi.buffer(0.5 * font_size, splits: false).coordinates.flatten(1).convex_hull
        next unless labelling_hull.surrounds? hull

        path_id = [@name, collection.layer_name, "path", label_index, feature_index, indices.first, indices.last].join ?.
        path_element = REXML::Element.new("path")
        path_element.add_attributes "id" => path_id, "d" => svg_path_data(baseline), "pathLength" => VALUE % text_length
        text_element = REXML::Element.new("text")

        case collection.text
        when REXML::Element
          fixed = true
          text_element.add_element collection.text, "href" => "#%s" % path_id
        when String
          text_path = text_element.add_element "textPath", "href" => "#%s" % path_id, "textLength" => VALUE % text_length, "spacing" => "auto"
          text_path.add_element("tspan", "dy" => VALUE % (CENTRELINE_FRACTION * font_size)).add_text(collection.text)
        end
        Label.new collection, label_index, feature_index, barrier_count, priority, [hull], attributes, [text_element, path_element], along, fixed
      end.compact.reject(&:optional?).sort.each.with_object({}) do |candidate, nearby|
        nearby[candidate] = []
      end.tap do |nearby|
        nearby.keys.nearby_pairs(closed) do |pair|
          diff = pair.map(&:along).inject(&:-)
          2 * (closed ? [diff % total, -diff % total].min : diff.abs) < sample
        end.each do |pair|
          nearby[pair[0]] << pair[1]
          nearby[pair[1]] << pair[0]
        end
        nearby.each do |candidate, others|
          others.each do |candidate|
            nearby.delete candidate
          end
        end
      end.keys.tap do |candidates|
        candidates.sort_by(&:along).inject do |(*candidates), candidate2|
          while candidates.any?
            break if (candidate2.along - candidates.first.along) % total < separation + text_length
            candidates.shift
          end
          candidates.each do |candidate1|
            candidate1.conflicts << candidate2
            candidate2.conflicts << candidate1
          end.push(candidate2)
        end if separation
      end
    end

    def label_candidates(&debug)
      label_features.flat_map.with_index do |collection, label_index|
        log_update "compositing %s: feature %i of %i" % [@name, label_index + 1, label_features.length]
        collection.each do |feature|
          font_size = feature.properties["font-size"]
          feature.properties.slice(*FONT_SCALED_ATTRIBUTES).each do |key, value|
            feature.properties[key] = value.to_i * font_size * 0.01 if /^\d+%$/ === value
          end
        end.flat_map do |feature|
          case feature
          when GeoJSON::Point, GeoJSON::LineString
            feature
          when GeoJSON::Polygon
            feature.coordinates.map do |ring|
              GeoJSON::LineString.new ring, feature.properties
            end
          end
        end.tap do |features|
          features.each.with_object("feature", &debug) if Config["debug"]
        end.flat_map.with_index do |feature, feature_index|
          case feature
          when GeoJSON::Point
            point_candidates(collection, label_index, feature_index, feature)
          when GeoJSON::LineString
            line_string_candidates(collection, label_index, feature_index, feature)
          end
        end.tap do |candidates|
          candidates.reject!(&:point?) unless candidates.all?(&:point?)
        end.sort.each.with_index do |candidate, index|
          candidate.priority = index
        end
      end.tap do |candidates|
        log_update "compositing %s: chosing label positions" % @name

        if Config["debug"]
          candidates.flat_map(&:hulls).each.with_object("candidate", &debug)
          candidates.clear
        end

        Label.overlaps(candidates).each do |candidate1, candidate2|
          next if candidate1.coexists_with? candidate2
          next if candidate2.coexists_with? candidate1
          candidate1.conflicts << candidate2
          candidate2.conflicts << candidate1
        end

        candidates.group_by do |candidate|
          [candidate.label_index, candidate["separation"]]
        end.each do |(label_index, buffer), candidates|
          Label.overlaps(candidates, buffer).each do |candidate1, candidate2|
            candidate1.conflicts << candidate2
            candidate2.conflicts << candidate1
          end if buffer
        end

        candidates.group_by do |candidate|
          [candidate.text, candidate.layer_name, candidate["separation-same"]]
        end.each do |(text, layer_name, buffer), candidates|
          Label.overlaps(candidates, buffer).each do |candidate1, candidate2|
            candidate1.conflicts << candidate2
            candidate2.conflicts << candidate1
          end if buffer
        end

        candidates.group_by do |candidate|
          [candidate.layer_name, candidate["separation-all"]]
        end.each do |(layer_name, buffer), candidates|
          Label.overlaps(candidates, buffer).each do |candidate1, candidate2|
            candidate1.conflicts << candidate2
            candidate2.conflicts << candidate1
          end if buffer
        end
      end
    end

    def drawing_features
      debug_features = []
      candidates = label_candidates do |feature, category|
        debug_features << [feature, Set["debug", category]]
      end

      conflicts = candidates.map do |candidate|
        [candidate, candidate.conflicts.dup]
      end.to_h
      labels, remaining, changed = Set.new, AVLTree.new, candidates
      grouped = candidates.to_set.classify(&:label_index)
      counts = Hash.new { |hash, label_index| hash[label_index] = 0 }

      loop do
        changed.each do |candidate|
          conflict_count = conflicts[candidate].count do |other|
            other.label_index != candidate.label_index
          end
          labelled = counts[candidate.label_index].zero? ? 0 : 1
          fixed = candidate.fixed ? 0 : 1
          ordinal = [fixed, conflict_count, labelled, candidate.priority]
          next if candidate.ordinal == ordinal
          remaining.delete candidate
          candidate.ordinal = ordinal
          remaining.insert candidate
        end
        break unless label = remaining.first
        labels << label
        first = counts[label.label_index].zero?
        counts[label.label_index] += 1
        removals = Set[label] | conflicts[label]
        removals.merge grouped[label.label_index].select(&:barriers?) if first
        removals.each do |candidate|
          grouped[candidate.label_index].delete candidate
          remaining.delete candidate
        end
        changed = conflicts.values_at(*removals).inject(Set[], &:|).subtract(removals).each do |candidate|
          conflicts[candidate].subtract removals
        end
        changed.merge grouped[label.label_index] if first
      end

      grouped = candidates.group_by(&:indices)
      5.times do
        labels = labels.inject(labels.dup) do |labels, label|
          next labels unless label.point?
          labels.delete label
          labels << grouped[label.indices].min_by do |candidate|
            [(labels & candidate.conflicts - Set[label]).count, candidate.priority]
          end
        end
      end

      labels.flat_map do |label|
        label.elements.map do |element|
          [element, label["categories"]]
        end
      end.tap do |result|
        next unless debug_features.any?
        @params = DEBUG_PARAMS.deep_merge @params
        result.concat debug_features
      end
    end
  end
end

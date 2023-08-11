# Based on:
#   Fast Point-Feature Label Placement Algorithm for Real Time Screen Maps
#   (Missae Yamamoto, Gilberto Camara, Luiz Antonio Nogueira Lorena)

require_relative 'labels/barrier'

module NSWTopo
  module Labels
    include Vector, Log
    CENTRELINE_FRACTION = 0.35
    DEFAULT_SAMPLE = 5
    INSET = 1

    LABEL_ATTRIBUTES = %w[
      coexist
      curved
      font-family
      font-size
      font-style
      font-variant
      font-weight
      format
      knockout
      letter-spacing
      line-height
      margin
      max-angle
      max-turn
      min-radius
      optional
      orientation
      position
      sample
      separation
      separation-all
      separation-along
      shield
      upcase
      word-spacing
    ]

    LABEL_TRANSFORMS = %w[
      buffer
      fallback
      keep-largest
      minimum-area
      minimum-hole
      minimum-length
      offset
      reduce
      remove
      remove-holes
      smooth
      trim
    ]

    LABEL_PARAMS = LABEL_ATTRIBUTES + LABEL_TRANSFORMS + SVG_ATTRIBUTES

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
        stroke: hsl(260,100%,50%)
        stroke-width: 0.2
        symbol:
          circle:
            r: 0.3
            stroke: none
            fill: hsl(260,100%,50%)
      debug candidate:
        stroke: hsl(300,100%,50%)
        stroke-width: 0.2
    YAML

    def barriers
      @barriers ||= []
    end

    def label_features
      @label_features ||= []
    end

    module LabelFeatures
      attr_accessor :text, :dual, :layer_name
    end

    extend Forwardable
    delegate :<< => :barriers

    def add(layer)
      label_params = layer.params.fetch("labels", {})
      label_params.except(*LABEL_PARAMS).select do |key, value|
        Hash === value
      end.transform_keys do |categories|
        Array(categories).map do |category|
          [layer.name, category].join(?\s)
        end
      end.then do |params|
        { layer.name => label_params }.merge(params)
      end.transform_values do |params|
        params.slice(*LABEL_PARAMS)
      end.transform_values do |params|
        # handle legacy format for separation, separation-all, separation-along
        params.each.with_object("separation" => Hash[]) do |(key, value), hash|
          case [key, value]
          in ["separation",    Hash] then hash["separation"].merge! value
          in ["separation",       *] then hash["separation"].merge! "self"  => value
          in ["separation-all",   *] then hash["separation"].merge! "other" => value
          in ["separation-along", *] then hash["separation"].merge! "along" => value
          else hash[key] = value
          end
        end
      end.then do |category_params|
        @params.merge! category_params
      end

      feature_count = feature_total = 0
      layer.labeling_features.tap do |features|
        feature_total = features.length
      end.map(&:multi).group_by do |feature|
        Set[layer.name, *feature["category"]]
      end.each do |categories, features|
        transforms = params_for(categories).slice(*LABEL_TRANSFORMS)
        attributes, point_attributes, line_attributes = [nil, "point", "line"].map do |extra_category|
          categories | Set[*extra_category]
        end.map do |categories|
          params_for(categories).slice(*LABEL_ATTRIBUTES).merge("categories" => categories)
        end

        features.map do |feature|
          log_update "collecting labels: %s: feature %i of %i" % [layer.name, feature_count += 1, feature_total]
          text = feature["label"]
          text = case
          when REXML::Element === text then text
          when attributes["format"] then attributes["format"] % text
          else Array(text).map(&:to_s).map(&:strip).join(?\s)
          end
          dual = feature["dual"]
          text.upcase! if String === text && attributes["upcase"]
          dual.upcase! if String === dual && attributes["upcase"]

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
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE)
                  feature.respond_to?(arg) ? feature.send(arg, interval: interval, **opts) : feature
                when "centres"
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE)
                  feature.respond_to?(arg) ? feature.send(arg, interval: interval, **opts) : feature
                when "centroids"
                  feature.respond_to?(arg) ? feature.send(arg) : feature
                when "samples"
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE)
                  feature.respond_to?(arg) ? feature.send(arg, interval) : feature
                else
                  raise "unrecognised label transform: reduce: %s" % arg
                end

              when "fallback"
                case arg
                when "samples"
                  next feature unless feature.respond_to? arg
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE)
                  [feature, *feature.send(arg, interval)]
                else
                  raise "unrecognised label transform: fallback: %s" % arg
                end

              when "offset", "buffer"
                next feature unless feature.respond_to? transform
                margins = [arg, *args].map { |value| Float(value) }
                feature.send transform, *margins, **opts

              when "smooth"
                next feature unless feature.respond_to? transform
                margin = Float(arg)
                max_turn = attributes["max-turn"] * Math::PI / 180
                feature.send transform, margin, cutoff_angle: max_turn, **opts

              when "minimum-area"
                area = Float(arg)
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
                distance = Float(arg)
                feature.coordinates = feature.coordinates.reject do |linestring|
                  linestring.path_length < distance
                end
                feature.empty? ? [] : feature

              when "minimum-hole", "remove-holes"
                area = Float(arg).abs unless true == arg
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
                distance = Float(arg)
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
            GeoJSON::Collection.new(projection: @map.neatline.projection, features: features).explode.extend(LabelFeatures)
          end.tap do |collection|
            collection.text, collection.dual, collection.layer_name = text, dual, layer.name
          end
        end.then do |collections|
          next collections unless label_params["collate"]
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
      delegate %i[text dual layer_name] => :@collection
      delegate %i[[] dig] => :@attributes

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

      def bounds
        @hulls.flatten(1).transpose.map(&:minmax)
      end

      def self.overlaps?(label1, label2, buffer:)
        return false if label1 == label2
        [label1, label2].map(&:hulls).inject(&:product).any? do |hulls|
          hulls.overlap?(buffer)
        end
      end

      def self.overlaps(labels, &block)
        Enumerator.new do |yielder|
          next unless labels.any?(&block)
          index = RTree.load(labels, &:bounds)
          index.each do |bounds, label|
            next unless buffer = yield(label)
            index.search(bounds, buffer: buffer).with_object(label).select do |other, label|
              overlaps? label, other, buffer: buffer
            end.inject(yielder, &:<<)
          end
        end
      end
    end

    def labelling_hull
      # TODO: doesn't account for map insets, need to replace with generalised check for non-covex @map.neatline
      @labelling_hull ||= @map.neatline(mm: -INSET).coordinates.first.transpose.map(&:minmax).inject(&:product).values_at(0,2,3,1,0)
    end

    def barrier_segments
      @barrier_segments ||= barriers.flat_map(&:segments).then do |segments|
        RTree.load(segments, &:bounds)
      end
    end

    def point_candidates(collection, label_index, feature_index, feature)
      attributes  = feature.properties
      margin      = attributes["margin"]
      line_height = attributes["line-height"]
      font_size   = attributes["font-size"]

      point = feature.coordinates
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

        bounds = hulls.flatten(1).transpose.map(&:minmax)
        barrier_count = barrier_segments.search(bounds).with_object Set[] do |segment, barriers|
          next if barriers === segment.barrier
          hulls.any? do |hull|
            barriers << segment.barrier if segment.conflicts_with? hull
          end
        end.size
        priority = [position_index, feature_index]
        Label.new collection, label_index, feature_index, barrier_count, priority, hulls, attributes, text_elements
      end.compact.reject do |candidate|
        candidate.optional? && candidate.barriers?
      end.tap do |candidates|
        candidates.combination(2).each do |candidate1, candidate2|
          candidate1.conflicts << candidate2
          candidate2.conflicts << candidate1
        end
      end
    end

    def line_string_candidates(collection, label_index, feature_index, feature)
      attributes  = feature.properties
      orientation = attributes["orientation"]
      max_turn    = attributes["max-turn"] * Math::PI / 180
      min_radius  = attributes["min-radius"]
      max_angle   = attributes["max-angle"] * Math::PI / 180
      curved      = attributes["curved"]
      sample      = attributes["sample"]
      font_size   = attributes["font-size"]

      closed = feature.coordinates.first == feature.coordinates.last
      buffer = 0.5 * font_size

      text_length = case collection.text
      when REXML::Element then feature.coordinates.path_length
      when String then Font.glyph_length collection.text, attributes
      end

      barrier_overlaps = Hash.new do |overlaps, label_segment|
        bounds = label_segment.transpose.map(&:minmax)
        overlaps[label_segment] = barrier_segments.search(bounds, buffer: buffer).select do |barrier_segment|
          barrier_segment.conflicts_with?(label_segment, buffer: buffer)
        end.inject Set[] do |barriers, segment|
          barriers.add segment.barrier
        end
      end

      points, deltas, angles, avoid = feature.coordinates.each_cons(2).flat_map do |v0, v1|
        next [v0] if REXML::Element === collection.text
        distance = v1.minus(v0).norm
        next [v0] if curved && distance >= text_length
        (0...1).step(sample/distance).map do |fraction|
          v0.times(1 - fraction).plus(v1.times(fraction))
        end
      end.then do |points|
        if closed
          v0, v2 = points.last, points.first
          points.unshift(v0).push(v2)
        else
          points.push(feature.coordinates.last).unshift(nil).push(nil)
        end
      end.each_cons(3).map do |v0, v1, v2|
        next v1, 0, 0, 0 unless v0
        next v1, v1.minus(v0).norm, 0, 0 unless v2
        o01, o12, o20 = v1.minus(v0), v2.minus(v1), v0.minus(v2)
        l01, l12, l20 = o01.norm, o12.norm, o20.norm
        h01, h12 = o01 / l01, o12 / l12
        angle = Math::atan2 h01.cross(h12), h01.dot(h12)
        semiperimeter = (l01 + l12 + l20) / 2
        area_squared = [0, semiperimeter * (semiperimeter - l01) * (semiperimeter - l12) * (semiperimeter - l20)].max
        curvature = 4 * Math::sqrt(area_squared) / (l01 * l12 * l20)
        avoid = angle.abs > max_angle || min_radius * (curvature || 0) > 1
        next v1, l01, angle, avoid
      end.transpose

      total, distances = deltas.inject([0, []]) do |(total, distances), delta|
        next total += delta, distances << total
      end

      start = points.length.times
      stop = closed ? points.length.times.cycle : points.length.times
      indices = [stop.next]

      Enumerator.produce do
        while indices.length > 1 && deltas.values_at(*indices).drop(1).sum > text_length do
          start.next
          indices.shift
        end
        until indices.length > 1 && deltas.values_at(*indices).drop(1).sum > text_length do
          indices.push stop.next
        end

        angle_sum, angle_sum_min, angle_sum_max, angle_square_sum = angles.values_at(*indices[1...-1]).inject [0, 0, 0, 0] do |(sum, min, max, square_sum), angle|
          next sum += angle, [min, sum].min, [max, sum].max, square_sum + angle**2
        end

        redo if angle_sum_max - angle_sum_min > max_turn
        redo if curved && indices.length < 3
        redo if avoid.values_at(*indices).any?

        baseline = points.values_at(*indices).crop(text_length)
        baseline.reverse! unless case orientation
        when "uphill", "anticlockwise" then true
        when "downhill", "clockwise" then false
        else baseline.values_at(0, -1).map(&:first).inject(&:<=)
        end

        offsets = baseline.each_cons(2).map do |p0, p1|
          p1.minus(p0).perp.normalised.times(buffer)
        end
        corners = offsets.each_cons(2).map do |d01, d12|
          d01.plus(d12).normalised.times(buffer * (d12.cross(d01) <=> 0))
        end
        hull = baseline.each_cons(2).zip(offsets, corners).each.with_object [] do |((p0, p1), offset, corner), buffered|
          buffered << p0.plus(offset) << p0.minus(offset) << p1.plus(offset) << p1.minus(offset)
          buffered << p1.plus(corner) if corner
        end.convex_hull
        redo unless labelling_hull.surrounds? hull

        barrier_count = baseline.each_cons(2).with_object Set[] do |segment, barriers|
          barriers.merge barrier_overlaps[segment]
        end.size

        along = distances.values_at(indices.first, indices.last).then do |d0, d1|
          (d0 + ((d1 - d0) % total) / 2) % total
        end
        priority = [angle_square_sum, (total - 2 * along).abs / total]

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
      end.reject do |candidate|
        candidate.optional? && candidate.barriers?
      end.then do |candidates|
        neighbours = Hash.new do |hash, candidate|
          hash[candidate] = Set[]
        end
        candidates.each.with_index do |candidate1, index1|
          index2 = index1
          loop do
            index2 = (index2 + 1) % candidates.length
            break if index2 == (closed ? index1 : 0)
            candidate2 = candidates[index2]
            offset = candidate2.along - candidate1.along
            break unless offset % total < sample || (closed && -offset % total < sample)
            neighbours[candidate2] << candidate1
            neighbours[candidate1] << candidate2
          end
        end
        removed = Set[]
        candidates.sort.each.with_object Array[] do |candidate, sampled|
          next if removed === candidate
          removed.merge neighbours[candidate]
          sampled << candidate
        end.tap do |candidates|
          next unless separation = attributes.dig("separation", "along")
          separation += text_length
          sorted = candidates.sort_by(&:along)
          sorted.each.with_index do |candidate1, index1|
            index2 = index1
            loop do
              index2 = (index2 + 1) % candidates.length
              break if index2 == (closed ? index1 : 0)
              candidate2 = sorted[index2]
              offset = candidate2.along - candidate1.along
              break unless offset % total < separation || (closed && -offset % total < separation)
              candidate2.conflicts << candidate1
              candidate1.conflicts << candidate2
            end
          end
        end
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
        log_update "compositing %s: choosing label positions" % @name

        if Config["debug"]
          candidates.flat_map(&:hulls).each.with_object("candidate", &debug)
          candidates.clear
        end

        Enumerator.new do |yielder|
          # separation/self: minimum distance between a label and another label for the same feature
          candidates.group_by do |label|
            label.label_index
          end.values.each do |group|
            Label.overlaps(group) do |label|
              label.dig("separation", "self")
            end.inject(yielder, &:<<)
          end

          # separation/same: minimum distance between a label and another label with the same text
          candidates.group_by do |label|
            [label.layer_name, label.text]
          end.values.each do |group|
            Label.overlaps(group) do |label|
              label.dig("separation", "same")
            end.inject(yielder, &:<<)
          end

          candidates.group_by do |candidate|
            candidate.layer_name
          end.each do |layer_name, group|
            index = RTree.load(group, &:bounds)

            # separation/other: minimum distance between a label and another label from the same layer
            index.each do |bounds, label|
              next unless buffer = label.dig("separation", "other")
              index.search(bounds, buffer: buffer).with_object(label).select do |other, label|
                Label.overlaps? label, other, buffer: buffer
              end.inject(yielder, &:<<)
            end

            # separation/<layer>: minimum distance between a label and any label from <layer>
            candidates.each do |label|
              next unless buffer = label.dig("separation", layer_name)
              index.search(label.bounds, buffer: buffer).with_object(label).select do |other, label|
                Label.overlaps? label, other, buffer: buffer
              end.inject(yielder, &:<<)
            end
          end

          # separation/dual: minimum distance between any two dual labels
          candidates.select(&:dual).group_by do |label|
            [label.layer_name, Set[label.text, label.dual]]
          end.values.each do |group|
            Label.overlaps(group) do |label|
              label.dig("separation", "dual")
            end.inject(yielder, &:<<)
          end

          # separation/all: minimum distance between a label and *any* other label
          Label.overlaps(candidates) do |label|
            # default of zero prevents any two labels overlapping
            label.dig("separation", "all") || 0
          end.reject do |label1, label2|
            label1.coexists_with?(label2) ||
            label2.coexists_with?(label1)
          end.inject(yielder, &:<<)
        end.each do |label1, label2|
          label1.conflicts << label2
          label2.conflicts << label1
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

      ordered, unlabeled = AVLTree.new, Hash.new(true)
      remaining = candidates.to_set.classify(&:label_index)

      Enumerator.produce do |label|
        if label
          removals = Set[label] | conflicts[label]
          if first = unlabeled[label.label_index]
            removals.merge remaining[label.label_index].select(&:barriers?)
            unlabeled[label.label_index] = false
          end

          removals.each do |candidate|
            remaining[candidate.label_index].delete candidate
            ordered.delete candidate
          end

          conflicts.values_at(*removals).inject(Set[], &:|).subtract(removals).each do |candidate|
            conflicts[candidate].subtract removals
          end.tap do |changed|
            changed.merge remaining[label.label_index] if first
          end
        else
          candidates
        end.each do |candidate|
          conflict_count = conflicts[candidate].each.with_object Set[] do |other, indices|
            indices << other.label_index
          end.delete(candidate.label_index).size
          conflict_count += candidate.barrier_count

          unsafe = candidate.conflicts.classify(&:label_index).any? do |label_index, conflicts|
            next false unless unlabeled[label_index]
            others = remaining[label_index].reject(&:optional?)
            others.any? && others.all?(conflicts)
          end

          ordinal = [
            candidate.fixed                  ? 0 : 1, # fixed grid-line labels
            candidate.optional?              ? 1 : 0, # non-optional candidates
            unsafe                           ? 1 : 0, # candidates which don't prevent another feature being labeled altogether
            unlabeled[candidate.label_index] ? 0 : 1, # candidates for unlabeled features
            conflict_count,                           # candidates with fewer conflicts
            candidate.priority                        # better quality candidates
          ]

          unless candidate.ordinal == ordinal
            ordered.delete candidate
            candidate.ordinal = ordinal
            ordered.insert candidate
          end
        end

        ordered.first or raise StopIteration
      end.to_set.tap do |labels|
        grouped = candidates.group_by(&:indices)
        5.times do
          labels.select(&:point?).each do |label|
            labels.delete label
            labels << grouped[label.indices].min_by do |candidate|
              [(labels & candidate.conflicts - Set[label]).count, candidate.priority]
            end
          end
        end
      end.flat_map do |label|
        label.elements.map.with_object(label["categories"]).entries
      end.tap do |result|
        next unless debug_features.any?
        @params = DEBUG_PARAMS.deep_merge @params
        result.concat debug_features
      end
    end
  end
end

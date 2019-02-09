require_relative 'labels/fence'

module NSWTopo
  module Labels
    include Vector, Log
    CENTRELINE_FRACTION = 0.35
    DEFAULT_SAMPLE = 5
    INSET = 1

    PROPERTIES = %w[font-size font-family font-variant font-style font-weight letter-spacing word-spacing margin orientation position separation separation-along separation-all max-turn min-radius max-angle format categories optional sample line-height upcase shield curved]
    TRANSFORMS = %w[reduce fallback offset buffer smooth remove-holes minimum-area minimum-hole minimum-length remove keep-largest trim]

    DEFAULTS = YAML.load <<~YAML
      dupe: outline
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
      outline:
        stroke: white
        fill: none
        stroke-width: 0.25
        stroke-opacity: 0.75
        blur: 0.06
    YAML

    DEBUG_PARAMS = YAML.load <<~YAML
      debug:
        dupe: ~
        fill: none
        opacity: 0.5
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

    def fences
      @fences ||= []
    end

    def add_fence(feature, buffer)
      index = fences.length
      case feature
      when GeoJSON::Point
        [[feature.coordinates.yield_self(&to_mm)] * 2]
      when GeoJSON::LineString
        feature.coordinates.map(&to_mm).segments
      when GeoJSON::Polygon
        feature.coordinates.flat_map { |ring| ring.map(&to_mm).segments }
      end.each do |segment|
        fences << Fence.new(segment, buffer: buffer, index: index)
      end
    end

    def label_features
      @label_features ||= []
    end

    module LabelFeatures
      attr_accessor :text, :layer_name
    end

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
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE) * @map.scale / 1000.0
                  feature.respond_to?(arg) ? feature.send(arg, interval: interval, **opts) : feature
                when "centres"
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE) * @map.scale / 1000.0
                  feature.respond_to?(arg) ? feature.send(arg, interval: interval, **opts) : feature
                when "centroids"
                  feature.respond_to?(arg) ? feature.send(arg) : feature
                when "samples"
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE) * @map.scale / 1000.0
                  feature.respond_to?(arg) ? feature.send(arg, interval) : feature
                else
                  raise "unrecognised label transform: reduce: %s" % arg
                end

              when "fallback"
                case arg
                when "samples"
                  next feature unless feature.respond_to? arg
                  interval = Float(opts.delete(:interval) || DEFAULT_SAMPLE) * @map.scale / 1000.0
                  [feature, *feature.send(arg, interval)]
                else
                  raise "unrecognised label transform: fallback: %s" % arg
                end

              when "offset", "buffer"
                next feature unless feature.respond_to? transform
                margins = [arg, *args].map { |value| Float(value) * @map.scale / 1000.0 }
                feature.send transform, *margins, **opts

              when "smooth"
                next feature unless feature.respond_to? transform
                margin = Float(arg) * @map.scale / 1000.0
                max_turn = attributes["max-turn"] * Math::PI / 180
                feature.send transform, margin, cutoff_angle: max_turn, **opts

              when "minimum-area"
                area = Float(arg) * (@map.scale / 1000.0)**2
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
                distance = Float(arg) * @map.scale / 1000.0
                feature.coordinates = feature.coordinates.reject do |linestring|
                  linestring.path_length < distance
                end
                feature.empty? ? [] : feature

              when "minimum-hole", "remove-holes"
                area = Float(arg).abs * @map.scale / 1000.0 unless true == arg
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
                distance = Float(arg) * @map.scale / 1000.0
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
          end.yield_self do |features|
            GeoJSON::Collection.new(@map.projection, features).explode.extend(LabelFeatures)
          end.tap do |collection|
            collection.text, collection.layer_name = text, layer.name
          end
        end.yield_self do |collections|
          next collections unless collate
          collections.group_by(&:text).map do |text, collections|
            collections.inject(&:merge!)
          end
        end.each do |collection|
          label_features << collection
        end
      end
    end

    Label = Struct.new(:layer_name, :label_index, :feature_index, :priority, :hull, :attributes, :elements, :along) do
      def point?
        along.nil?
      end

      def optional?
        attributes["optional"]
      end

      def categories
        attributes["categories"]
      end

      def conflicts
        @conflicts ||= Set.new
      end

      attr_accessor :ordinal
      def <=>(other)
        self.ordinal <=> other.ordinal
      end

      alias hash object_id
      alias eql? equal?
    end

    def drawing_features
      fence_index = RTree.load(fences, &:bounds)
      labelling_hull = @map.bounding_box(mm: -INSET).coordinates.first.map(&to_mm)
      debug, debug_features = Config["debug"], []
      @params = DEBUG_PARAMS.deep_merge @params if debug

      candidates = label_features.map.with_index do |collection, label_index|
        log_update "compositing %s: feature %i of %i" % [@name, label_index + 1, label_features.length]
        collection.flat_map do |feature|
          case feature
          when GeoJSON::Point, GeoJSON::LineString
            feature
          when GeoJSON::Polygon
            feature.coordinates.map do |ring|
              GeoJSON::LineString.new ring, feature.properties
            end
          end
        end.map.with_index do |feature, feature_index|
          attributes = feature.properties
          font_size = attributes["font-size"]
          attributes.slice(*FONT_SCALED_ATTRIBUTES).each do |key, value|
            attributes[key] = value.to_i * font_size * 0.01 if value =~ /^\d+%$/
          end

          debug_features << [feature, Set["debug", "feature"]] if debug
          next [] if debug == "features"

          case feature
          when GeoJSON::Point
            margin, line_height = attributes.values_at "margin", "line-height"
            point = feature.coordinates.yield_self(&to_mm)
            lines = Font.in_two collection.text, attributes
            lines = [[collection.text, Font.glyph_length(collection.text, attributes)]] if lines.map(&:first).map(&:length).min == 1
            width = lines.map(&:last).max
            height = lines.map { font_size }.inject { |total| total + line_height }
            if attributes["shield"]
              width += SHIELD_X * font_size
              height += SHIELD_Y * font_size
            end
            [*attributes["position"] || "over"].map.with_index do |position, position_index|
              dx = position =~ /right$/ ? 1 : position =~ /left$/  ? -1 : 0
              dy = position =~ /^below/ ? 1 : position =~ /^above/ ? -1 : 0
              f = dx * dy == 0 ? 1 : 0.707
              origin = [dx, dy].times(f * margin).plus(point)

              text_elements = lines.map.with_index do |(line, text_length), index|
                y = (lines.one? ? 0 : dy == 0 ? index - 0.5 : index + 0.5 * (dy - 1)) * line_height
                y += (CENTRELINE_FRACTION + 0.5 * dy) * font_size
                REXML::Element.new("text").tap do |text|
                  text.add_attribute "transform", "translate(%s)" % POINT % origin
                  text.add_attribute "text-anchor", dx > 0 ? "start" : dx < 0 ? "end" : "middle"
                  text.add_attribute "textLength", VALUE % text_length
                  text.add_attribute "y", VALUE % y
                  text.add_text line
                end
              end

              hull = [[dx, width], [dy, height]].map do |d, l|
                [d * f * margin + (d - 1) * 0.5 * l, d * f * margin + (d + 1) * 0.5 * l]
              end.inject(&:product).values_at(0,2,3,1).map do |corner|
                corner.plus point
              end
              next unless labelling_hull.surrounds? hull

              fence_count = fence_index.search(hull.transpose.map(&:minmax)).inject(Set[]) do |indices, fence|
                next indices if indices === fence.index
                fence.conflicts_with?(hull) ? indices << fence.index : indices
              end.size
              priority = [fence_count, position_index, feature_index]
              Label.new collection.layer_name, label_index, feature_index, priority, hull, attributes, text_elements
            end.compact.tap do |candidates|
              candidates.combination(2).each do |candidate1, candidate2|
                candidate1.conflicts << candidate2
                candidate2.conflicts << candidate1
              end
            end
          when GeoJSON::LineString
            closed = feature.coordinates.first == feature.coordinates.last
            pairs = closed ? :ring : :segments
            data = feature.coordinates.map(&to_mm)

            orientation = attributes["orientation"]
            max_turn    = attributes["max-turn"] * Math::PI / 180
            min_radius  = attributes["min-radius"]
            max_angle   = attributes["max-angle"] * Math::PI / 180
            curved      = attributes["curved"]
            sample      = attributes["sample"]
            separation  = attributes["separation-along"]

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
            vectors = segments.map(&:difference)
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

            overlaps = Hash.new do |hash, segment|
              bounds = segment.transpose.map(&:minmax).map do |min, max|
                [min - 0.5 * font_size, max + 0.5 * font_size]
              end
              hash[segment] = fence_index.search(bounds).any? do |fence|
                fence.conflicts_with? segment, 0.5 * font_size
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

              fence = baseline.segments.any? do |segment|
                overlaps[segment]
              end
              priority = [fence ? 1 : 0, total_squared_curvature, (total - 2 * along).abs / total.to_f]

              case
              when "uphill" == orientation
              when "downhill" == orientation then baseline.reverse!
              when baseline.values_at(0, -1).map(&:first).inject(&:<=)
              else baseline.reverse!
              end

              hull = GeoJSON::LineString.new(baseline).multi.buffer(0.5 * font_size, splits: false).coordinates.flatten(1).convex_hull
              next unless labelling_hull.surrounds? hull

              path_id = [@name, collection.layer_name, "path", label_index, feature_index, indices.first, indices.last].join ?.
              path_element = REXML::Element.new("path")
              path_element.add_attributes "id" => path_id, "d" => svg_path_data(baseline), "pathLength" => VALUE % text_length
              text_element = REXML::Element.new("text")

              case collection.text
              when REXML::Element
                text_element.add_element collection.text, "xlink:href" => "#%s" % path_id
              when String
                text_path = text_element.add_element "textPath", "xlink:href" => "#%s" % path_id, "textLength" => VALUE % text_length, "spacing" => "auto"
                text_path.add_element("tspan", "dy" => VALUE % (CENTRELINE_FRACTION * font_size)).add_text(collection.text)
              end
              Label.new collection.layer_name, label_index, feature_index, priority, hull, attributes, [text_element, path_element], along
            end.compact.map do |candidate|
              [candidate, []]
            end.to_h.tap do |matrix|
              matrix.keys.nearby_pairs(closed) do |pair|
                diff = pair.map(&:along).inject(&:-)
                2 * (closed ? [diff % total, -diff % total].min : diff.abs) < sample
              end.each do |pair|
                matrix[pair[0]] << pair[1]
                matrix[pair[1]] << pair[0]
              end
            end.sort_by do |candidate, nearby|
              candidate.priority
            end.to_h.tap do |matrix|
              matrix.each do |candidate, nearby|
                nearby.each do |candidate|
                  matrix.delete candidate
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
        end.flatten.tap do |candidates|
          candidates.reject!(&:point?) unless candidates.all?(&:point?)
        end.sort_by(&:priority).each.with_index do |candidate, index|
          candidate.priority = index
        end
      end.flatten

      candidates.each do |candidate|
        debug_features << [candidate.hull, Set["debug", "candidate"]]
      end if debug
      return debug_features if %w[features candidates].include? debug

      candidates.map(&:hull).overlaps.map do |indices|
        candidates.values_at *indices
      end.each do |candidate1, candidate2|
        candidate1.conflicts << candidate2
        candidate2.conflicts << candidate1
      end

      candidates.group_by do |candidate|
        [candidate.label_index, candidate.attributes["separation"]]
      end.each do |(label_index, buffer), candidates|
        candidates.map(&:hull).overlaps(buffer).map do |indices|
          candidates.values_at *indices
        end.each do |candidate1, candidate2|
          candidate1.conflicts << candidate2
          candidate2.conflicts << candidate1
        end if buffer
      end

      candidates.group_by do |candidate|
        [candidate.layer_name, candidate.attributes["separation-all"]]
      end.each do |(layer_name, buffer), candidates|
        candidates.map(&:hull).overlaps(buffer).map do |indices|
          candidates.values_at *indices
        end.each do |candidate1, candidate2|
          candidate1.conflicts << candidate2
          candidate2.conflicts << candidate1
        end if buffer
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
          optional = candidate.optional? ? 1 : 0
          grid = candidate.layer_name == "grid" ? 0 : 1
          ordinal = [grid, optional, conflict_count, labelled, candidate.priority]
          next if candidate.ordinal == ordinal
          remaining.delete candidate
          candidate.ordinal = ordinal
          remaining.insert candidate
        end
        break unless label = remaining.first
        labels << label
        counts[label.label_index] += 1
        removals = Set[label] | conflicts[label]
        removals.each do |candidate|
          grouped[candidate.label_index].delete candidate
          remaining.delete candidate
        end
        changed = conflicts.values_at(*removals).inject(Set[], &:|).subtract(removals).each do |candidate|
          conflicts[candidate].subtract removals
        end
        changed.merge grouped[label.label_index] if counts[label.label_index] == 1
      end

      candidates.reject(&:optional?).group_by(&:label_index).select do |label_index, candidates|
        counts[label_index].zero?
      end.each do |label_index, candidates|
        label = candidates.min_by do |candidate|
          [(candidate.conflicts & labels).length, candidate.priority]
        end
        label.conflicts.intersection(labels).each do |other|
          next unless counts[other.label_index] > 1
          labels.delete other
          counts[other.label_index] -= 1
        end
        labels << label
        counts[label_index] += 1
      end if Config["allow-overlaps"]

      grouped = candidates.group_by do |candidate|
        [candidate.label_index, candidate.feature_index]
      end
      5.times do
        labels = labels.inject(labels.dup) do |labels, label|
          next labels unless label.point?
          labels.delete label
          labels << grouped[[label.label_index, label.feature_index]].min_by do |candidate|
            [(labels & candidate.conflicts - Set[label]).count, candidate.priority]
          end
        end
      end

      labels.map do |label|
        label.elements.map do |element|
          [element, label.categories]
        end
      end.flatten(1).tap do |result|
        result.concat debug_features if debug
      end
    end
  end
end

# module NSWTopo
#   class Label
#     include Vector

#     CENTRELINE_FRACTION = 0.35
#     ATTRIBUTES = %w[font-size font-family font-variant font-style font-weight letter-spacing word-spacing margin orientation position separation separation-along separation-all max-turn min-radius max-angle format collate categories optional sample line-height strip upcase shield curved]
#     TRANSFORMS = %w[reduce fallback outset inset offset buffer smooth remove-holes minimum-area minimum-hole minimum-length remove keep-largest trim]
#     SCALABLE_ATTRIBUTES = %w[letter-spacing word-spacing line-height]
#     DEFAULT_SAMPLE = 5
#     DEFAULT_PARAMS = %Q[
#       font-size: 1.8
#       line-height: 110%
#       margin: 1.0
#       max-turn: 60
#       min-radius: 0
#       max-angle: #{StraightSkeleton::DEFAULT_ROUNDING_ANGLE}
#       sample: #{DEFAULT_SAMPLE}
#     ]
#     PARAMS = %Q[
#       debug:
#         fill: none
#         opacity: 0.5
#       debug feature:
#         stroke: "#6600ff"
#         stroke-width: 0.2
#         symbol:
#           circle:
#             r: 0.3
#             stroke: none
#             fill: "#6600ff"
#       debug candidate:
#         stroke: magenta
#         stroke-width: 0.2
#     ]

#     def initialize
#       @name, @features = "labels", []
#       @params = YAML.load(PARAMS)
#     end

#     def add(source)
#       source_params = params[source.name] = [ YAML.load(DEFAULT_PARAMS), source.params[name] ].compact.inject(&:merge)
#       sublayers = Set.new
#       source.labels.group_by do |dimension, data, labels, categories, sublayer|
#         [ dimension, [ *categories ].map(&:to_s).reject(&:empty?).map(&:to_category).to_set ]
#       end.each do |(dimension, categories), features|
#         transforms, attributes, *dimensioned_attributes = [ nil, nil, "point", "line", "line" ].map do |extra_category|
#           categories | Set[*extra_category]
#         end.zip([ TRANSFORMS, ATTRIBUTES, ATTRIBUTES, ATTRIBUTES, ATTRIBUTES ]).map do |categories, keys|
#           source_params.select do |key, value|
#             value.is_a?(Hash)
#           end.select do |key, value|
#             [ *key ].any? { |string| string.to_s.split.map(&:to_category).to_set <= categories }
#           end.values.push("categories" => categories).inject(source_params, &:merge).select do |key, value|
#             keys.include? key
#           end
#         end
#         max_turn = attributes["max-turn"]
#         features.each do |_, data, labels, _, sublayer|
#           text = case
#           when REXML::Element === labels then labels
#           when attributes["format"] then attributes["format"] % labels
#           else [ *labels ].map(&:to_s).map(&:strip).reject(&:empty?).join(?\s)
#           end
#           [ *attributes["strip"] ].each do |strip|
#             text.gsub! strip, ''
#           end
#           text.upcase! if String === text && attributes["upcase"]
#           yield sublayer unless sublayers.include? sublayer
#           sublayers << sublayer
#           _, _, _, components = @features.find do |other_text, other_source_name, other_sublayer, _|
#             other_source_name == source.name && other_text == text && other_sublayer == sublayer
#           end if attributes["collate"]
#           unless components
#             components = [ ]
#             @features << [ text, source.name, sublayer, components ]
#           end
#           data = case dimension
#           when 0
#             CONFIG.map.coords_to_mm data
#           when 1, 2
#             data.map do |coords|
#               CONFIG.map.coords_to_mm coords
#             end
#           end
#           transforms.inject([ [ dimension, data ] ]) do |dimensioned_data, (transform, (arg, *args))|
#             next dimensioned_data unless arg
#             opts, args = args.partition do |arg|
#               Hash === arg
#             end
#             opts = opts.inject({}, &:merge)
#             dimensioned_data.map do |dimension, data|
#               closed = dimension == 2
#               transformed = case transform
#               when "reduce"
#                 case arg
#                 when "skeleton"
#                   next [ [ 1, data.skeleton ] ] if closed
#                 when "centrelines"
#                   next data.centres [ 1 ], *args, opts if closed
#                 when "centrepoints"
#                   opts["interval"] ||= DEFAULT_SAMPLE
#                   next data.centres [ 0 ], *args, opts if closed
#                 when "centres"
#                   opts["interval"] ||= DEFAULT_SAMPLE
#                   next data.centres [ 1, 0 ], *args, opts if closed
#                 when "centroids"
#                   next [ [ 0, data.reject(&:hole?).map(&:centroid) ] ] if closed
#                 when "intervals"
#                   interval = args[0] || DEFAULT_SAMPLE
#                   case dimension
#                   when 1 then next [ [ 0, data.sample_outwards(interval) ] ]
#                   when 2 then next [ [ 0, data.sample_at(interval) ] ]
#                   end
#                 end
#               when "fallback"
#                 case arg
#                 when "intervals"
#                   interval = args[0] || DEFAULT_SAMPLE
#                   next [ [ 1, data ], [ 0, data.sample_outwards(interval) ] ] if dimension == 1
#                 end
#               when "outset"
#                 data.outset(arg, opts) if dimension > 0
#               when "inset"
#                 data.inset(arg, opts) if dimension > 0
#               when "offset"
#                 data.offset(arg, *args, opts) if dimension > 0
#               when "buffer"
#                 data.buffer(closed, arg, *args) if dimension > 0
#               when "smooth"
#                 next [ [ 1, data.smooth(arg, max_turn) ] ] if dimension > 0
#               when "minimum-area"
#                 case dimension
#                 when 1
#                   data.reject do |points|
#                     points.last == points.first && points.signed_area.abs < arg
#                   end
#                 when 2
#                   data.chunk(&:hole?).map(&:last).each_slice(2).map do |polys, holes|
#                     keep = polys.map do |points|
#                       [ points, points.signed_area > arg ]
#                     end
#                     keep.select(&:last).map(&:first).tap do |result|
#                       result += holes if holes && keep.last.last
#                     end
#                   end.flatten(1)
#                 end
#               when "minimum-hole", "remove-holes"
#                 data.reject do |points|
#                   case arg
#                   when true then points.signed_area < 0
#                   when Numeric then (-arg.abs ... 0).include? points.signed_area
#                   end
#                 end if closed
#               when "minimum-length"
#                 data.reject do |points|
#                   points.segments.map(&:distance).inject(0.0, &:+) < arg && points.first == points.last
#                 end if dimension == 1
#               when "remove"
#                 [ ] if [ arg, *args ].any? do |value|
#                   case value
#                   when true    then true
#                   when String  then text == value
#                   when Regexp  then text =~ value
#                   when Numeric then text == value.to_s
#                   end
#                 end
#               when "keep-largest"
#                 case dimension
#                 when 1 then [ data.max_by(&:signed_area) ]
#                 when 2 then [ data.max_by(&:path_length) ]
#                 end
#               when "trim"
#                 data.map do |points|
#                   points.trim arg
#                 end.reject(&:empty?) if dimension == 1
#               end
#               [ [ dimension, transformed || data ] ]
#             end.flatten(1)
#           end.each do |dimension, data|
#             data.each do |point_or_points|
#               components << [ dimension, point_or_points, dimensioned_attributes[dimension] ]
#             end
#           end
#         end
#       end if source.respond_to? :labels

#       fences.concat source.fences if source.respond_to? :fences
#     end

#     Label = Struct.new(:source_name, :sublayer, :feature, :component, :priority, :hull, :attributes, :elements, :along) do
#       def point?
#         along.nil?
#       end

#       def optional?
#         attributes["optional"]
#       end

#       def categories
#         attributes["categories"]
#       end

#       def conflicts
#         @conflicts ||= Set.new
#       end

#       attr_accessor :ordinal
#       def <=>(other)
#         self.ordinal <=> other.ordinal
#       end

#       alias hash object_id
#       alias eql? equal?
#     end

#     def features
#       labelling_hull, debug_features = CONFIG.map.mm_corners(-1), []
#       fence_segments = fences.map.with_index do |(dimension, feature, buffer), index|
#         case dimension
#         when 0 then feature.map { |point| [ point ] }
#         when 1, 2 then feature.map(&:segments).flatten(1)
#         end.map do |segment|
#           [ segment, [ buffer, index ] ]
#         end
#       end.flatten(1)
#       fence_index = RTree.load(fence_segments) do |fence, (buffer, *)|
#         fence.transpose.map(&:minmax).map do |min, max|
#           [ min - buffer, max + buffer ]
#         end
#       end

#       candidates = @features.map.with_index do |(text, source_name, sublayer, components), feature|
#         components.map.with_index do |(dimension, data, attributes), component|
#           font_size = attributes["font-size"]
#           SCALABLE_ATTRIBUTES.each do |name|
#             attributes[name] = attributes[name].to_i * font_size * 0.01 if /^\d+%$/ === attributes[name]
#           end
#           debug_features << [ dimension, [ data ], %w[debug feature] ] if CONFIG["debug"]
#           next [] if CONFIG["debug"] == "features"
#           case dimension
#           when 0
#             margin, line_height = attributes.values_at "margin", "line-height"
#             lines = Font.in_two text, attributes
#             lines = [ [ text, Font.glyph_length(text, attributes) ] ] if lines.map(&:first).map(&:length).min == 1
#             width = lines.map(&:last).max
#             height = lines.map { font_size }.inject { |total| total + line_height }
#             if attributes["shield"]
#               width += VectorLayer::SHIELD_X * font_size
#               height += VectorLayer::SHIELD_Y * font_size
#             end
#             [ *attributes["position"] || "over" ].map.with_index do |position, position_index|
#               dx = position =~ /right$/ ? 1 : position =~ /left$/  ? -1 : 0
#               dy = position =~ /^below/ ? 1 : position =~ /^above/ ? -1 : 0
#               f = dx * dy == 0 ? 1 : 0.707
#               offset = [ dx, dy ].map do |d|
#                 d * margin * f
#               end
#               text_attributes = {
#                 "transform" => "translate(#{data.join ?\s}) rotate(#{-CONFIG.map.rotation}) translate(#{offset.join ?\s})",
#                 "text-anchor" => dx > 0 ? "start" : dx < 0 ? "end" : "middle",
#               }

#               text_elements = lines.map.with_index do |(line, text_length), index|
#                 y = (lines.one? ? 0 : dy == 0 ? index - 0.5 : index + 0.5 * (dy - 1)) * line_height
#                 y += (CENTRELINE_FRACTION + 0.5 * dy) * font_size
#                 REXML::Element.new("text").tap do |text|
#                   text.add_attributes text_attributes
#                   text.add_attribute "textLength", text_length
#                   text.add_attribute "y", y
#                   text.add_text line
#                 end
#               end
#               hull = [ [ dx, width ], [ dy, height ] ].map do |d, l|
#                 [ d * f * margin + (d - 1) * 0.5 * l, d * f * margin + (d + 1) * 0.5 * l ]
#               end.inject(&:product).values_at(0,2,3,1).map do |corner|
#                 corner.rotate_by_degrees(-CONFIG.map.rotation).plus(data)
#               end
#               next unless labelling_hull.surrounds?(hull).all?
#               fence_count = fence_index.search(hull.transpose.map(&:minmax)).inject(Set[]) do |indices, (fence, (buffer, index))|
#                 next indices if indices.include? index
#                 next indices unless [ hull, fence ].overlap?(buffer)
#                 indices << index
#               end.size
#               priority = [ fence_count, position_index, component ]
#               Label.new source_name, sublayer, feature, component, priority, hull, attributes, text_elements
#             end.compact.tap do |candidates|
#               candidates.combination(2).each do |candidate1, candidate2|
#                 candidate1.conflicts << candidate2
#                 candidate2.conflicts << candidate1
#               end
#             end
#           when 1, 2
#             closed = dimension == 2
#             pairs = closed ? :ring : :segments
#             orientation = attributes["orientation"]
#             max_turn    = attributes["max-turn"] * Math::PI / 180
#             min_radius  = attributes["min-radius"]
#             max_angle   = attributes["max-angle"] * Math::PI / 180
#             curved      = attributes["curved"]
#             sample      = attributes["sample"]
#             separation  = attributes["separation-along"]
#             text_length = case text
#             when REXML::Element then data.path_length
#             when String then Font.glyph_length text, attributes
#             end
#             points = data.segments.inject([]) do |memo, segment|
#               distance = segment.distance
#               case
#               when REXML::Element === text
#                 memo << segment[0]
#               when curved && distance >= text_length
#                 memo << segment[0]
#               else
#                 steps = (distance / sample).ceil
#                 memo += steps.times.map do |step|
#                   segment.along(step.to_f / steps)
#                 end
#               end
#             end
#             points << data.last unless closed
#             segments = points.send(pairs)
#             vectors = segments.map(&:difference)
#             distances = vectors.map(&:norm)
#             cumulative = distances.inject([0]) do |memo, distance|
#               memo << memo.last + distance
#             end
#             total = closed ? cumulative.pop : cumulative.last
#             angles = vectors.map(&:normalised).send(pairs).map do |directions|
#               Math.atan2 directions.inject(&:cross), directions.inject(&:dot)
#             end
#             closed ? angles.rotate!(-1) : angles.unshift(0).push(0)
#             curvatures = segments.send(pairs).map do |(p0, p1), (_, p2)|
#               sides = [ [ p0, p1 ], [ p1, p2 ], [ p2, p0 ] ].map(&:distance)
#               semiperimeter = 0.5 * sides.inject(&:+)
#               diffs = sides.map { |side| semiperimeter - side }
#               area_squared = [ semiperimeter * diffs.inject(&:*), 0 ].max
#               4 * Math::sqrt(area_squared) / sides.inject(&:*)
#             end
#             closed ? curvatures.rotate!(-1) : curvatures.unshift(0).push(0)
#             dont_use = angles.zip(curvatures).map do |angle, curvature|
#               angle.abs > max_angle || min_radius * curvature > 1
#             end
#             squared_angles = angles.map { |angle| angle * angle }
#             overlaps = Hash.new do |hash, segment|
#               bounds = segment.transpose.map(&:minmax).map do |min, max|
#                 [ min - 0.5 * font_size, max + 0.5 * font_size ]
#               end
#               hash[segment] = fence_index.search(bounds).any? do |fence, (buffer, *)|
#                 [ segment, fence ].overlap?(buffer + 0.5 * font_size)
#               end
#             end
#             Enumerator.new do |yielder|
#               indices, distance, bad_indices, angle_integral = [ 0 ], 0, [ ], [ ]
#               loop do
#                 while distance < text_length
#                   break true if closed ? indices.many? && indices.last == indices.first : indices.last == points.length - 1
#                   unless indices.one?
#                     bad_indices << dont_use[indices.last]
#                     angle_integral << (angle_integral.last || 0) + angles[indices.last]
#                   end
#                   distance += distances[indices.last]
#                   indices << (indices.last + 1) % points.length
#                 end && break
#                 while distance >= text_length
#                   case
#                   when indices.length == 2 && curved
#                   when indices.length == 2 then yielder << indices.dup
#                   when distance - distances[indices.first] >= text_length
#                   when bad_indices.any?
#                   when angle_integral.max - angle_integral.min > max_turn
#                   else yielder << indices.dup
#                   end
#                   angle_integral.shift
#                   bad_indices.shift
#                   distance -= distances[indices.first]
#                   indices.shift
#                   break true if indices.first == (closed ? 0 : points.length - 1)
#                 end && break
#               end if points.many?
#             end.map do |indices|
#               start, stop = cumulative.values_at(*indices)
#               along = (start + 0.5 * (stop - start) % total) % total
#               total_squared_curvature = squared_angles.values_at(*indices[1...-1]).inject(0, &:+)
#               baseline = points.values_at(*indices).crop(text_length)
#               fence = baseline.segments.any? do |segment|
#                 overlaps[segment]
#               end
#               priority = [ fence ? 1 : 0, total_squared_curvature, (total - 2 * along).abs / total.to_f ]
#               case orientation
#               when "uphill"
#               when "downhill" then baseline.reverse!
#               else baseline.reverse! unless baseline.values_at(0, -1).difference.rotate_by_degrees(CONFIG.map.rotation).first > 0
#               end
#               hull = [ baseline, baseline.reverse ].map do |line|
#                 [ line ].inset(0.5 * font_size, "splits" => false)
#               end.flatten(2).convex_hull
#               next unless labelling_hull.surrounds?(hull).all?
#               baseline << baseline.last(2).difference.normalised.times(text_length * 0.25).plus(baseline.last)
#               path_id = [ name, source_name, "path", feature, component, indices.first, indices.last ].join SEGMENT
#               path_element = REXML::Element.new("path")
#               path_element.add_attributes "id" => path_id, "d" => [ baseline ].to_path_data(MM_DECIMAL_DIGITS), "pathLength" => baseline.path_length.round(MM_DECIMAL_DIGITS)
#               text_element = REXML::Element.new("text")
#               case text
#               when REXML::Element
#                 text_element.add_element text, "xlink:href" => "##{path_id}"
#               when String
#                 text_path = text_element.add_element "textPath", "xlink:href" => "##{path_id}", "textLength" => text_length.round(MM_DECIMAL_DIGITS), "spacing" => "auto"
#                 text_path.add_element("tspan", "dy" => CENTRELINE_FRACTION * font_size).add_text(text)
#               end
#               Label.new source_name, sublayer, feature, component, priority, hull, attributes, [ text_element, path_element ], along
#             end.compact.map do |candidate|
#               [ candidate, [] ]
#             end.to_h.tap do |matrix|
#               matrix.keys.nearby_pairs(closed) do |pair|
#                 diff = pair.map(&:along).inject(&:-)
#                 2 * (closed ? [ diff % total, -diff % total ].min : diff.abs) < sample
#               end.each do |pair|
#                 matrix[pair[0]] << pair[1]
#                 matrix[pair[1]] << pair[0]
#               end
#             end.sort_by do |candidate, nearby|
#               candidate.priority
#             end.to_h.tap do |matrix|
#               matrix.each do |candidate, nearby|
#                 nearby.each do |candidate|
#                   matrix.delete candidate
#                 end
#               end
#             end.keys.tap do |candidates|
#               candidates.sort_by(&:along).inject do |(*candidates), candidate2|
#                 while candidates.any?
#                   break if (candidate2.along - candidates.first.along) % total < separation + text_length
#                   candidates.shift
#                 end
#                 candidates.each do |candidate1|
#                   candidate1.conflicts << candidate2
#                   candidate2.conflicts << candidate1
#                 end.push(candidate2)
#               end if separation
#             end
#           end
#         end.flatten.tap do |candidates|
#           candidates.reject!(&:point?) unless candidates.all?(&:point?)
#         end.sort_by(&:priority).each.with_index do |candidate, index|
#           candidate.priority = index
#         end
#       end.flatten

#       candidates.each do |candidate|
#         debug_features << [ 2, [ candidate.hull ], %w[debug candidate] ]
#       end if CONFIG["debug"]
#       return debug_features if %w[features candidates].include? CONFIG["debug"]

#       candidates.map(&:hull).overlaps.map do |indices|
#         candidates.values_at *indices
#       end.each do |candidate1, candidate2|
#         candidate1.conflicts << candidate2
#         candidate2.conflicts << candidate1
#       end

#       candidates.group_by do |candidate|
#         [ candidate.feature, candidate.attributes["separation"] ]
#       end.each do |(feature, buffer), candidates|
#         candidates.map(&:hull).overlaps(buffer).map do |indices|
#           candidates.values_at *indices
#         end.each do |candidate1, candidate2|
#           candidate1.conflicts << candidate2
#           candidate2.conflicts << candidate1
#         end if buffer
#       end

#       candidates.group_by do |candidate|
#         [ candidate.source_name, candidate.sublayer, candidate.attributes["separation-all"] ]
#       end.each do |(source_name, sublayer, buffer), candidates|
#         candidates.map(&:hull).overlaps(buffer).map do |indices|
#           candidates.values_at *indices
#         end.each do |candidate1, candidate2|
#           candidate1.conflicts << candidate2
#           candidate2.conflicts << candidate1
#         end if buffer
#       end

#       conflicts = candidates.map do |candidate|
#         [ candidate, candidate.conflicts.dup ]
#       end.to_h
#       labels, remaining, changed = Set.new, AVLTree.new, candidates
#       grouped = candidates.to_set.classify(&:feature)
#       counts = Hash.new { |hash, feature| hash[feature] = 0 }

#       loop do
#         changed.each do |candidate|
#           conflict_count = conflicts[candidate].count do |other|
#             other.feature != candidate.feature
#           end
#           labelled = counts[candidate.feature].zero? ? 0 : 1
#           optional = candidate.optional? ? 1 : 0
#           ordinal = [ optional, conflict_count, labelled, candidate.priority ]
#           next if candidate.ordinal == ordinal
#           remaining.delete candidate
#           candidate.ordinal = ordinal
#           remaining.insert candidate
#         end
#         break unless label = remaining.first
#         labels << label
#         counts[label.feature] += 1
#         removals = Set[label] | conflicts[label]
#         removals.each do |candidate|
#           grouped[candidate.feature].delete candidate
#           remaining.delete candidate
#         end
#         changed = conflicts.values_at(*removals).inject(Set[], &:|).subtract(removals).each do |candidate|
#           conflicts[candidate].subtract removals
#         end
#         changed.merge grouped[label.feature] if counts[label.feature] == 1
#       end

#       candidates.reject(&:optional?).group_by(&:feature).select do |feature, candidates|
#         counts[feature].zero?
#       end.each do |feature, candidates|
#         label = candidates.min_by do |candidate|
#           [ (candidate.conflicts & labels).length, candidate.priority ]
#         end
#         label.conflicts.intersection(labels).each do |other|
#           next unless counts[other.feature] > 1
#           labels.delete other
#           counts[other.feature] -= 1
#         end
#         labels << label
#         counts[feature] += 1
#       end if CONFIG["allow-overlaps"]

#       grouped = candidates.group_by do |candidate|
#         [ candidate.feature, candidate.component ]
#       end
#       5.times do
#         labels = labels.inject(labels.dup) do |labels, label|
#           next labels unless label.point?
#           labels.delete label
#           labels << grouped[[ label.feature, label.component ]].min_by do |candidate|
#             [ (labels & candidate.conflicts - Set[label]).count, candidate.priority ]
#           end
#         end
#       end

#       labels.map do |label|
#         [ nil, label.elements, label.categories, label.source_name ]
#       end.tap do |result|
#         result.concat debug_features if CONFIG["debug"]
#       end
#     end
#   end
# end

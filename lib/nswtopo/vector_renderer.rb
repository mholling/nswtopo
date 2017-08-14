module NSWTopo
  module VectorRenderer
    SHIELD_X, SHIELD_Y = 1.0, 0.5
    SVG_PRESENTATION_ATTRIBUTES = %w[fill-opacity fill font-family font-size font-style font-variant font-weight letter-spacing opacity stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit stroke-opacity stroke-width stroke text-decoration visibility word-spacing]
    SCALABLE_ATTRIBUTES = %w[word-spacing letter-spacing stroke-width]
    attr_reader :name, :params

    def fences
      @fences ||= []
    end

    def render_svg(xml, map)
      defs = xml.elements["svg/defs"]
      unless map.rotation.zero?
        w, h = map.bounds.map { |bound| 1000.0 * (bound.max - bound.min) / map.scale }
        t = Math::tan(map.rotation * Math::PI / 180.0)
        d = (t * t - 1) * Math::sqrt(t * t + 1)
        if t >= 0
          y = (t * (h * t - w) / d).abs
          x = (t * y).abs
        else
          x = -(t * (h + w * t) / d).abs
          y = -(t * x).abs
        end
        transform = "translate(#{x} #{-y}) rotate(#{map.rotation})"
      end

      features(map).group_by do |dimension, feature, categories, sublayer, *|
        sublayer
      end.each do |sublayer, features|
        next unless group = yield(sublayer)
        puts "  #{sublayer}" if sublayer
        group.add_attributes("transform" => transform) if transform
        sublayer_actions = params.merge params.fetch(sublayer, {})

        features.reject do |dimension, feature, *|
          feature.empty?
        end.group_by do |dimension, feature, categories, *|
          [ *categories ].map(&:to_s).map(&:to_category).to_set
        end.map do |categories, features|
          actions = sublayer_actions.select do |command, args|
            [ command ].flatten.any? do |filter|
              filter.to_s.split.to_set <= categories
            end
          end.values.inject(sublayer_actions, &:merge)
          [ *actions["dupe"] ].map do |dupe|
            [ categories + Set[dupe], [ name, *sublayer, *categories, "content" ].join(SEGMENT) ]
          end.push [ categories, features ]
        end.flatten(1).map do |categories, features|
          ids = [ name, *sublayer, *categories ]
          case features
          when String
            container = group.add_element "use", "xlink:href" => "##{features}", "class" => categories.map(&:to_s).join(?\s)
          when Array
            container = group.add_element "g", "class" => categories.map(&:to_s).join(?\s)
            content = container.add_element "g", "id" => [ *ids, "content" ].join(SEGMENT)
          end
          container.add_attribute "id", ids.join(SEGMENT) if categories.any?
          [ categories, features, container, content ]
        end.each do |categories, features, container, content|
          ids = [ name, *sublayer, *categories ]
          commands = sublayer_actions.select do |command, args|
            [ command ].flatten.any? do |filter|
              filter.to_s.split.to_set <= categories
            end
          end.values.inject(sublayer_actions, &:merge)
          font_size, bezier, section = commands.values_at "font-size", "bezier", "section"
          SCALABLE_ATTRIBUTES.each do |attribute|
            commands[attribute] = (commands[attribute].to_i * font_size * 0.01).round(4) if /^\d+%$/ === commands[attribute]
          end
          features.each do |dimension, feature, _, _, angle|
            case dimension
            when 0
              symbol_id = [ name, *sublayer, *categories, "symbol"].join(SEGMENT)
              feature.each do |x, y|
                content.add_element "use", "transform" => "translate(#{x} #{y}) rotate(#{angle || -map.rotation})", "xlink:href" => "##{symbol_id}"
              end
            when 1 then
              (section ? feature.in_sections(section).zip : [ feature ]).each do |feature|
                content.add_element "path", "fill" => "none", "d" => feature.to_path_data(MM_DECIMAL_DIGITS, false, bezier)
              end
            when 2 then
              content.add_element "path", "fill-rule" => "nonzero", "d" => feature.to_path_data(MM_DECIMAL_DIGITS, true, bezier)
            when nil
              feature.each do |element|
                case element.name
                when "text", "textPath" then content << element
                when "path" then defs << element
                end
              end
            end
          end if content
          commands.each do |command, args|
            next unless args
            args = args.map(&:to_a).inject([], &:+) if Array === args && args.all? { |arg| Hash === arg }
            case command
            when "blur"
              filter_id = [ *ids, "blur" ].join(SEGMENT)
              container.add_attribute "filter", "url(##{filter_id})"
              defs.add_element("filter", "id" => filter_id).add_element "feGaussianBlur", "stdDeviation" => args, "in" => "SourceGraphic"
            when "opacity"
              if sublayer_actions["opacity"] == args
                group.add_attribute "style", "opacity:#{args}"
              else
                container.add_attribute "opacity", args
              end
            when "symbol"
              next unless content
              symbol_id = [ *ids, "symbol"].join(SEGMENT)
              defs.add_element("g", "id" => symbol_id).tap do |symbol|
                args.each { |element, attributes| symbol.add_element element, attributes }
              end
            when "pattern"
              args = args.to_a
              width  = args.delete(args.find { |key, value| key == "width"  }).last
              height = args.delete(args.find { |key, value| key == "height" }).last
              pattern_id = [ *ids, "pattern"].join(SEGMENT)
              defs.add_element("pattern", "id" => pattern_id, "patternUnits" => "userSpaceOnUse", "patternTransform" => "rotate(#{-map.rotation})", "width" => width, "height" => height).tap do |pattern|
                args.each { |element, attributes| pattern.add_element element, attributes }
              end
              container.add_attribute "fill", "url(##{pattern_id})"
            when "symbolise"
              next unless content
              args = args.to_a
              interval = args.delete(args.find { |key, value| key == "interval" }).last
              symbol_ids = args.map.with_index do |(element, attributes), index|
                [ *ids, "symbol", index ].join(SEGMENT).tap do |symbol_id|
                  defs.add_element("g", "id" => symbol_id).add_element(element, attributes)
                end
              end
              features.each do |dimension, feature, *|
                feature.at_interval(dimension == 2, interval).each do |point, angle|
                  translate = point.round(MM_DECIMAL_DIGITS).join ?\s
                  rotate = (180.0 * angle / Math::PI).round(2)
                  content.add_element "use", "transform" => "translate(#{translate}) rotate(#{rotate})", "xlink:href" => "##{symbol_ids.sample}"
                end if dimension && dimension != 0
              end
            when "inpoint", "outpoint", "endpoint"
              next unless content
              symbol_id = [ *ids, command ].join(SEGMENT)
              defs.add_element("g", "id" => symbol_id).tap do |symbol|
                args.each { |element, attributes| symbol.add_element element, attributes }
              end
              features.each do |dimension, feature, *|
                feature.each do |line|
                  case command
                  when "inpoint"  then [ line.first(2) ]
                  when "outpoint" then [ line.last(2).rotate ]
                  when "endpoint" then [ line.first(2), line.last(2).rotate ]
                  end.each do |segment|
                    angle = 180.0 * segment.difference.angle / Math::PI
                    translate = segment[0].round(MM_DECIMAL_DIGITS).join ?\s
                    container.add_element "use", "transform" => "translate(#{translate}) rotate(#{angle.round 2})", "xlink:href" => "##{symbol_id}"
                  end
                end if dimension == 1
              end
            when "fence"
              buffer = 0.5 * (Numeric === args ? args : commands.fetch("stroke-width", 0))
              features.each do |dimension, feature, *|
                case dimension
                when 0 then feature.map { |point| [ point ] }
                when 1 then feature.map(&:segments).flatten(1)
                when 2 then feature.map(&:ring).flatten(1)
                end.each do |fence|
                  fences << [ fence, buffer ]
                end
              end if content
            when "shield"
              next unless content
              content.elements.each("text") do |element|
                font_size, letter_spacing, word_spacing = %w[font-size letter-spacing word-spacing].map do |name|
                  element.elements["./ancestor::g[@#{name}]/@#{name}"]
                end.map do |attribute|
                  attribute ? attribute.value.to_f : 0
                end
                group = REXML::Element.new("g")
                width, height = element.text.glyph_length(font_size, letter_spacing, word_spacing) + SHIELD_X * font_size, (1 + SHIELD_Y) * font_size
                group.add_element "rect", "x" => -0.5 * width, "y" => -0.5 * height, "width" => width, "height" => height, "rx" => font_size * 0.3, "ry" => font_size * 0.3, "stroke" => "none", "fill" => args
                text_transform = element.attributes.get_attribute "transform"
                text_transform.remove
                group.attributes << text_transform
                element.parent.elements << group
                group << element
              end
            when *SVG_PRESENTATION_ATTRIBUTES
              container.add_attribute command, args
            end
          end
        end.tap do |categorised|
          sublayer_actions.fetch("order", []).reverse.map(&:split).map(&:to_set).each do |filter|
            categorised.select do |categories, features, container, content|
              filter <= categories
            end.reverse.each do |categories, features, container, content|
              group.unshift container.remove
            end
          end
        end
        until group.elements.each(".//g[not(*)]", &:remove).empty? do
        end
      end
    end
  end
end

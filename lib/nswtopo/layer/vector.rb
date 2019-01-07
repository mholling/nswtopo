module NSWTopo
  module Vector
    SVG_ATTRIBUTES = %w[fill-opacity fill font-family font-size font-style font-variant font-weight letter-spacing opacity stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit stroke-opacity stroke-width stroke text-decoration visibility word-spacing]
    SCALABLE_ATTRIBUTES = %w[word-spacing letter-spacing stroke-width]
    SHIELD_X, SHIELD_Y = 1.0, 0.5
    MARGIN = { mm: 1.0 }

    def create
      collection = get_features.reproject_to(@map.projection).clip!(@map.bounding_box(MARGIN).coordinates.first)
      # TODO: enforce conditions for labels and categories? convert labels to string here?

      @map.write filename, collection.to_json
    end

    def filename
      "#{@name}.json"
    end

    def features
      GeoJSON::Collection.load @map.read(filename)
    end

    def drawing_features
      features.explode.reject do |feature|
        feature.properties["nodraw"]
      end
    end

    extend Forwardable
    def_delegator :features, :none?, :empty?

    def to_s
      count = features.count
      "%s: %i feature%s" % [ @name, count, (?s unless count == 1) ]
    end

    # TODO: decimal_places default value, link to GeoJSON SIGNIFICANT_FIGURES and/or COORDINATE_PRECISION
    def svg_path_data(points, decimal_places: 4, bezier: false)
      f = "%.#{decimal_places}f"
      if bezier
        fraction = [ 1.0, [ Numeric === bezier ? bezier : 1.0, 0.0 ].max ].min
        extras = points.first == points.last ? [ points[-2], *points, points[2] ] : [ points.first, *points, points.last ]
        midpoints = extras.segments.map(&:midpoint)
        distances = extras.segments.map(&:distance)
        offsets = midpoints.zip(distances).segments.map(&:transpose).map do |segment, distance|
          segment.along(distance.first / distance.inject(&:+))
        end.zip(points).map(&:difference)
        controls = midpoints.segments.zip(offsets).map do |segment, offset|
          segment.map { |point| [ point, point.plus(offset) ].along(fraction) }
        end.flatten(1).drop(1).each_slice(2).entries.prepend(nil)
        points.zip(controls).map do |point, controls|
          controls ? "C #{f} #{f} #{f} #{f} #{f} #{f}" % [ *controls.flatten, *point ] :  "M #{f} #{f}" % point
        end.join(" ")
      else
        points.map do |point|
          "#{f} #{f}" % point
        end.join(" L ").prepend("M ")
      end
    end

    def params_for(categories)
      params.select do |command, args|
        [ *command ].any? do |selector|
          selector.to_s.split.to_set <= categories
        end
      end.values.inject(params, &:merge)
    end

    def fences
      @fences ||= []
    end

    def render(group, defs)
      to_mm = @map.method(:coords_to_mm)

      drawing_features.group_by do |feature|
        feature.properties.fetch("categories", []).map(&:to_s).map(&:to_category).to_set
      end.map do |categories, features|
        dupes = params_for(categories)["dupe"]
        [ *dupes ].map(&:to_s).map do |dupe|
          [ categories | Set[dupe], [ name, *categories, "content" ].join(?.) ]
        end.push [ categories, features ]
      end.flatten(1).map do |categories, features|
        ids = [ name, *categories ]
        case features
        when String
          container = group.add_element "use", "class" => categories.to_a.join(?\s), "xlink:href" => "#%s" % features
        when Array
          container = group.add_element "g", "class" => categories.to_a.join(?\s)
          content = container.add_element "g", "id" => [ *ids, "content" ].join(?.)
        end
        container.add_attribute "id", ids.join(?.) if categories.any?

        commands = params_for categories
        font_size, bezier, section = commands.values_at "font-size", "bezier", "section"
        SCALABLE_ATTRIBUTES.each do |name|
          commands[name] = commands[name].to_i * font_size * 0.01 if /^\d+%$/ === commands[name]
        end

        features.each do |feature|
          case feature
          when GeoJSON::Point
            symbol_id = [ *ids, "symbol"].join(?.)
            # TODO: use same format string for rounding mm values here
            transform = "translate(%s %s) rotate(%s)" % [ *feature.coordinates.yield_self(&to_mm), feature.properties.fetch("angle", -@map.rotation) + @map.rotation ]
            content.add_element "use", "transform" => transform, "xlink:href" => "#%s" % symbol_id

          when GeoJSON::LineString
            linestring = feature.coordinates.map(&to_mm)
            (section ? linestring.in_sections(section) : [ linestring ]).each do |linestring|
              content.add_element "path", "fill" => "none", "d" => svg_path_data(linestring, bezier: bezier)
            end

          when GeoJSON::Polygon
            d = feature.coordinates.map do |ring|
              svg_path_data ring.map(&to_mm), bezier: bezier
            end.join(" Z ").concat(" Z")
            # TODO: check fill-rule!!!
            content.add_element "path", "fill-rule" => "nonzero", "d" => d

          # # TODO: re-introduce when we bring back Label layer
          # when REXML::Element
          #   case feature.name
          #   when "text", "textPath" then content << element
          #   when "path" then defs << element
          #   end
          end
        end if content

        commands.each do |command, args|
          next unless args
          args = args.map(&:to_a).inject([], &:+) if Array === args && args.all?(Hash)

          case command
          when "blur"
            filter_id = [ *ids, "blur" ].join(?.)
            container.add_attribute "filter", "url(#%s)" % filter_id
            defs.add_element("filter", "id" => filter_id).add_element "feGaussianBlur", "stdDeviation" => args, "in" => "SourceGraphic"

          when "opacity"
            if categories.none?
              group.add_attribute "style", "opacity:#{args}"
            else
              container.add_attribute "opacity", args
            end

          when "symbol"
            next unless content
            symbol = defs.add_element "g", "id" => [ *ids, "symbol"].join(?.)
            args.each do |element, attributes|
              symbol.add_element element, attributes
            end

          when "pattern"
            width, height = Hash[args].values_at "width", "height"
            pattern_id = [ *ids, "pattern"].join(?.)
            pattern = defs.add_element "pattern", "id" => pattern_id, "patternUnits" => "userSpaceOnUse", "width" => width, "height" => height
            args.each &pattern.method(:add_element)
            container.add_attribute "fill", "url(#%s)" % pattern_id

          when "symbolise"
            next unless content
            interval = Hash[args]["interval"]
            symbol_ids = args.map.with_index do |(element, attributes), index|
              symbol_id = [ *ids, "symbol", index ].join(?.).tap do |symbol_id|
                defs.add_element("g", "id" => symbol_id).add_element(element, attributes)
              end
            end
            lines_or_rings = features.grep(GeoJSON::LineString).map(&:coordinates)
            lines_or_rings += features.grep(GeoJSON::Polygon).map(&:coordinates).flatten(1)
            lines_or_rings.each do |points|
              points.map(&to_mm).sample_at(interval, :angle).each do |point, angle|
                # TODO: use same format string for rounding mm values here
                transform = "translate(%s %s) rotate(%s)" % [ *point, 180.0 * angle / Math::PI ]
                content.add_element "use", "transform" => transform, "xlink:href" => "#%s" % symbol_ids.sample
              end
            end

          when "inpoint", "outpoint", "endpoint"
            next unless content
            symbol_id = [ *ids, command ].join(?.)
            symbol = defs.add_element "g", "id" => symbol_id
            args.each &symbol.method(:add_element)
            features.grep(GeoJSON::LineString).map do |feature|
              feature.coordinates.map(&to_mm)
            end.each do |line|
              case command
              when "inpoint"  then [ line.first(2) ]
              when "outpoint" then [ line.last(2).rotate ]
              when "endpoint" then [ line.first(2), line.last(2).rotate ]
              end.each do |segment|
                # TODO: use same format string for rounding mm values here
                transform = "translate(%s %s) rotate(%s)" % [ *segment.first, 180.0 * segment.difference.angle / Math::PI ]
                container.add_element "use", "transform" => transform, "xlink:href" => "#%s" % symbol_id
              end
            end

          # # TODO: reinstate, works with Label layer
          # when "fence"
          #   next unless content
          #   buffer = 0.5 * (Numeric === args ? args : commands.fetch("stroke-width", 0))
          #   features.each do |feature|
          #     next if REXML::Element === features
          #     fences << [ feature, buffer ]
          #   end

          # # TODO: reinstate, works with Label layer
          # when "shield"
          #   next unless content
          #   content.elements.each("text") do |element|
          #     text_length = element.elements["./ancestor-or-self::[@textLength]/@textLength"].value.to_f
          #     group = REXML::Element.new("g")
          #     width, height = text_length + SHIELD_X * font_size, (1 + SHIELD_Y) * font_size
          #     group.add_element "rect", "x" => -0.5 * width, "y" => -0.5 * height, "width" => width, "height" => height, "rx" => font_size * 0.3, "ry" => font_size * 0.3, "stroke" => "none", "fill" => args
          #     text_transform = element.attributes.get_attribute "transform"
          #     text_transform.remove
          #     group.attributes << text_transform
          #     element.parent.elements << group
          #     group << element
          #   end

          when *SVG_ATTRIBUTES
            container.add_attribute command, args
          end
        end

        next categories, features, container
      end.tap do |categorised|
        params.fetch("order", []).reverse.map(&:split).map(&:to_set).each do |filter|
          categorised.select do |categories, features, container|
            filter <= categories
          end.reverse.each do |categories, features, container|
            group.unshift container.remove
          end
        end
      end

      until group.elements.each(".//g[not(*)]", &:remove).empty? do
      end
    end
  end
end

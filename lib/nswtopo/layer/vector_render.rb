require_relative 'vector_render/cutout'
require_relative 'vector_render/knockout'

module NSWTopo
  module VectorRender
    SVG_ATTRIBUTES = %w[
      fill-opacity
      fill
      font-family
      font-size
      font-style
      font-variant
      font-weight
      letter-spacing
      opacity
      paint-order
      stroke-dasharray
      stroke-dashoffset
      stroke-linecap
      stroke-linejoin
      stroke-miterlimit
      stroke-opacity
      stroke-width
      stroke
      text-decoration
      visibility
      word-spacing
      nswtopo:overprint
      nswtopo:stroke
      nswtopo:fill
    ]

    FONT_SCALED_ATTRIBUTES = %w[
      word-spacing
      letter-spacing
      stroke-width
      line-height
    ]

    SHIELD_X, SHIELD_Y = 1.0, 0.5
    MARGIN = { mm: 1.0 }
    VALUE, POINT, ANGLE = "%.5f", "%.5f %.5f", "%.2f"

    def create
      @features = get_features.reproject_to(@map.neatline.projection).clip(@map.neatline(**MARGIN))
      @map.write filename, @features.to_json
    end

    def filename
      "#{@name}.json"
    end

    def features
      @features ||= GeoJSON::Collection.load @map.read(filename)
    end

    extend Forwardable
    def_delegator :features, :none?, :empty?

    def drawing_features
      features.explode.reject do |feature|
        feature["draw"] == false
      end
    end

    def labeling_features
      features.select do |feature|
        feature["label"]
      end
    end

    def to_s
      count = features.count
      "%s: %i feature%s" % [@name, count, (?s unless count == 1)]
    end

    def categorise(string)
      string.tr_s('^_a-zA-Z0-9', ?-).delete_prefix(?-).delete_suffix(?-)
    end

    def svg_path_data(points, bezier: false)
      if bezier
        fraction = Numeric === bezier ? bezier.clamp(0, 1) : 1
        extras = points.first == points.last ? [points[-2], *points, points[2]] : [points.first, *points, points.last]
        midpoints = extras.each_cons(2).map do |p0, p1|
          (p0 + p1) / 2
        end
        distances = extras.each_cons(2).map do |p0, p1|
          (p1 - p0).norm
        end
        offsets = midpoints.zip(distances).each_cons(2).map do |(m0, d0), (m1, d1)|
          (m0 * d1 + m1 * d0) / (d0 + d1)
        end.zip(points).map do |p0, p1|
          p1 - p0
        end
        controls = midpoints.each_cons(2).zip(offsets).flat_map do |(m0, m1), offset|
          next m0 + offset * fraction, m1 + offset * fraction
        end.drop(1).each_slice(2).entries.prepend(nil)
        points.zip(controls).map do |point, controls|
          controls ? "C %s %s %s" % [POINT, POINT, POINT] % [*controls.flatten, *point] : "M %s" % POINT % point
        end.join(" ")
      else
        points.map do |point|
          POINT % point
        end.join(" L ").prepend("M ")
      end
    end

    def params_for(categories)
      params.select do |key, value|
        Array(key).any? do |selector|
          String(selector).split(?\s).to_set <= categories
        end
      end.values.inject(params, &:deep_merge)
    end

    def render(knockout:, **, &block)
      defs = REXML::Element.new("defs").tap(&block)
      defs.add_attributes "id" => "#{@name}.defs"

      drawing_features.group_by do |feature, categories|
        categories || Array(feature["category"]).map(&:to_s).map(&method(:categorise)).to_set
      end.flat_map do |categories, features|
        dupes = params_for(categories)["dupe"]
        Array(dupes).map(&:to_s).map do |dupe|
          [categories | Set[dupe], [name, *categories, "content"].join(?.)]
        end.push [categories, features]
      end.tap do |ordered|
        params.fetch("order", []).reverse.map(&:split).map(&:to_set).each do |filter|
          ordered.sort_by!.with_index do |(categories, features), index|
            [filter <= categories ? 0 : 1, index]
          end
        end
      end.each do |categories, features|
        ids = [name, *categories]
        use = REXML::Element.new("use")
        use.add_attributes "id" => ids.join(?.)

        case features
        when String
          use.add_attributes "href" => "##{features}"
        when Array
          content = defs.add_element "g", "id" => [*ids, "content"].join(?.)
          use.add_attributes "href" => "#" + [*ids, "content"].join(?.)
        end
        use.tap(&block)

        category_params = params_for(categories)
        font_size, stroke_width, bezier, section = category_params.values_at "font-size", "stroke-width", "bezier", "section"

        category_params.slice(*SVG_ATTRIBUTES).tap do |svg_attributes|
          svg_attributes.slice(*FONT_SCALED_ATTRIBUTES).each do |key, value|
            svg_attributes[key] = svg_attributes[key].to_i * font_size * 0.01 if /^\d+%$/ === value
          end if font_size
          use.add_attributes svg_attributes
        end

        features.each do |feature, _|
          case feature
          when GeoJSON::Point
            symbol_id = [*ids, "symbol"].join(?.)
            transform = "translate(%s) rotate(%s)" % [POINT, ANGLE] % [*feature.coordinates, feature.fetch("rotation", @map.rotation) - @map.rotation]
            content.add_element "use", "transform" => transform, "href" => "#%s" % symbol_id

          when GeoJSON::LineString
            linestring = feature.coordinates
            (section ? linestring.in_sections(section) : [linestring]).each do |linestring|
              content.add_element "path", "fill" => "none", "d" => svg_path_data(linestring, bezier: bezier)
            end

          when GeoJSON::Polygon
            path_data = feature.coordinates.map do |ring|
              svg_path_data ring, bezier: bezier
            end.each.with_object("Z").entries.join(?\s)
            content.add_element "path", "fill-rule" => "nonzero", "d" => path_data

          when REXML::Element
            case feature.name
            when "text", "textPath" then content << feature
            when "path" then defs << feature
            end

          when Array
            content.add_element "path", "fill" => "none", "d" => svg_path_data(feature + feature.take(1))
          end
        end if content

        category_params.each do |command, args|
          next unless args
          args = args.map(&:to_a).inject([], &:+) if Array === args && args.all?(Hash)

          case command
          when "blur"
            filter_id = [*ids, "blur"].join(?.)
            use.add_attribute "filter", "url(#%s)" % filter_id
            defs.add_element("filter", "id" => filter_id).add_element "feGaussianBlur", "stdDeviation" => args, "in" => "SourceGraphic"

          when "symbol"
            next unless content
            symbol = defs.add_element "g", "id" => [*ids, "symbol"].join(?.)
            args.each do |element, attributes|
              if attributes
                symbol.add_element element, attributes
              else
                symbol.add_element REXML::Document.new(element).root
              end
            end

          when "pattern"
            dimensions, args = args.partition do |key, value|
              %w[width height].include? key
            end
            width, height = Hash[dimensions].values_at "width", "height"
            pattern_id = [*ids, "pattern"].join(?.)
            pattern = defs.add_element "pattern", "id" => pattern_id, "patternUnits" => "userSpaceOnUse", "width" => width, "height" => height
            args.each do |element, attributes|
              pattern.add_element element, attributes
            end
            use.add_attribute "fill", "url(#%s)" % pattern_id

          when "symbolise"
            next unless content
            args, symbols = args.partition do |element, attributes|
              %w[interval offset].include? element
            end
            interval, offset = Hash[args].values_at "interval", "offset"
            symbol_ids = symbols.map.with_index do |(element, attributes), index|
              symbol_id = [*ids, "symbol", index].join(?.).tap do |symbol_id|
                defs.add_element("g", "id" => symbol_id).add_element(element, attributes)
              end
            end
            rings = features.grep(GeoJSON::Polygon).map(&:rings).flat_map(&:explode)
            lines = features.grep(GeoJSON::LineString)
            (rings + lines).each do |feature|
              feature.sample_at(interval, offset: offset) do |point, along, angle|
                "translate(%s) rotate(%s)" % [POINT, ANGLE] % [*point, 180.0 * angle / Math::PI]
              end.each do |transform|
                content.add_element "use", "transform" => transform, "href" => "#%s" % symbol_ids.sample
              end
            end

          when "inpoint", "outpoint", "endpoint"
            next unless content
            symbol_id = [*ids, command].join(?.)
            symbol = defs.add_element "g", "id" => symbol_id
            args.each do |element, attributes|
              symbol.add_element element, attributes
            end
            features.grep(GeoJSON::LineString).map(&:coordinates).each do |line|
              case command
              when "inpoint"  then [line.first(2)]
              when "outpoint" then [line.last(2).rotate]
              when "endpoint" then [line.first(2), line.last(2).rotate]
              end.each do |v0, v1|
                transform = "translate(%s) rotate(%s)" % [POINT, ANGLE] % [*v0, 180.0 * (v1 - v0).angle / Math::PI]
                use.add_element "use", "transform" => transform, "href" => "#%s" % symbol_id
              end
            end

          when "knockout"
            use.add_attributes "mask" => "url(##{knockout})"
            Knockout.new(use, *args).tap(&block)

          when "preserve"
            use.add_attributes "mask" => "none"

          when "cutout", "mask"   # mask deprecated
            Cutout.new(use).tap(&block)

          when "barrier", "fence" # fence deprecated
            next unless content && args
            buffer = 0.5 * (Numeric === args ? args : Numeric === stroke_width ? stroke_width : 0)
            features.grep_v(REXML::Element).each do |feature|
              Labels::Barrier.new(feature, buffer).tap(&block)
            end

          when "shield"
            next unless content
            content.elements.each("text") do |element|
              case
              when text_length = element.elements["./ancestor-or-self::[@textLength]/@textLength"]&.value&.to_f
                shield = REXML::Element.new("g")
                width, height = text_length + SHIELD_X * font_size, (1 + SHIELD_Y) * font_size
                shield.add_element "rect", "x" => -0.5 * width, "y" => -0.5 * height, "width" => width, "height" => height, "rx" => font_size * 0.3, "ry" => font_size * 0.3, "stroke" => "none", "fill" => args
                text_transform = element.attributes.get_attribute "transform"
                text_transform.remove
                shield.attributes << text_transform
                element.parent.elements << shield
                shield << element
              when href = element.elements["./textPath[@href]/@href"]&.value
                shield = REXML::Element.new("g")
                shield.add_element "use", "href" => href, "stroke-width" => (1 + SHIELD_Y) * font_size, "stroke" => args, "stroke-linecap" => "round"
                element.parent.elements << shield
                shield << element
              end
            end
          end
        end
      end
    end
  end
end

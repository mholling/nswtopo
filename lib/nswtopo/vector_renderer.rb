module NSWTopo
  module VectorRenderer
    SVG_PRESENTATION_ATTRIBUTES = %w[fill-opacity fill font-family font-size font-style font-variant font-weight letter-spacing opacity stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit stroke-opacity stroke-width stroke text-decoration visibility word-spacing]
    
    attr_reader :name, :params, :sublayers
    
    def predicate_for(category)
      case category
      when nil then "@class=''"
      when ""  then "@class"
      else "@class='#{category}' or starts-with(@class,'#{category} ') or contains(@class,' #{category} ') or ends-with(@class,' #{category}')"
      end
    end
    
    def render_svg(xml, map)
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
      
      groups = { }
      draw(map) do |element, sublayer, defs|
        group = groups[sublayer] ||= yield(sublayer).tap do |group|
          group.add_attributes("transform" => transform) if group && transform
        end
        (defs ? xml.elements["//svg/defs"] : group).add_element(element) if group
      end
      
      xml.elements.each("/svg/g[@id='#{name}' or starts-with(@id,'#{name}#{SEGMENT}')][*]") do |group|
        id = group.attributes["id"]
        sublayer = id.split(/^#{name}#{SEGMENT}?/).last
        [ *params, *params[sublayer] ].inject({}) do |memo, (command, args)|
          memo.deep_merge case command
          when "symbol"    then { "symbols" => { "" => args } }
          when "pattern"   then { "patterns" => { "" => args } }
          when "dupe"      then { "dupes" => { "" => args } }
          when "sample"    then { "samples" => { "" => args } }
          when "endpoint"  then { "inpoints" => { "" => args }, "outpoints" => { "" => args } }
          when "endpoints" then { "inpoints" => args, "outpoints" => args }
          when "inpoint"   then { "inpoints" => { "" => args } }
          when "outpoint"  then { "outpoints" => { "" => args } }
          else { command => args }
          end
        end.inject([]) do |memo, (command, args)|
          case command
          when %r{^\./} then memo << [ command, args ]
          when "opacity" then memo << [ "self::/@style", "opacity:#{args}" ]
          when "dash"
            case args
            when nil             then memo << [ ".//[@stroke-dasharray]/@stroke-dasharray", nil ]
            when String, Numeric then memo << [ ".//path", { "stroke-dasharray" => args } ]
            end
          when "order"
            args.reverse.map do |category|
              "./g[#{predicate_for category}]"
            end.each do |xpath|
              group.elements.collect(xpath, &:remove).reverse.each do |element|
                group.unshift element
              end
            end
          when "symbols"
            args.each do |categories, elements|
              [ categories ].flatten.map do |category|
                [ "./g[#{predicate_for category}]/use[not(xlink:href)]", [ id, *category.split(?\s), "symbol" ].join(SEGMENT) ]
              end.select do |xpath, symbol_id|
                group.elements[xpath]
              end.each do |xpath, symbol_id|
                memo << [ "//svg/defs", { "g" => { "id" => symbol_id } } ]
                memo << [ "//svg/defs/g[@id='#{symbol_id}']", elements ]
                memo << [ xpath, { "xlink:href" => "##{symbol_id}"} ]
              end
            end
          when "patterns"
            args.each do |categories, elements|
              [ categories ].flatten.map do |category|
                [ "./g[#{predicate_for category}]", [ id, *category.split(?\s), "pattern" ].join(SEGMENT) ]
              end.select do |xpath, pattern_id|
                group.elements["#{xpath}//path[not(@fill='none')]"]
              end.each do |xpath, pattern_id|
                memo << [ "//svg/defs", { "pattern" => { "id" => pattern_id, "patternUnits" => "userSpaceOnUse", "patternTransform" => "rotate(#{-map.rotation})" } } ]
                memo << [ "//svg/defs/pattern[@id='#{pattern_id}']", elements ]
                memo << [ xpath, { "fill" => "url(##{pattern_id})"} ]
              end
            end
          when "dupes"
            args.each do |categories, names|
              [ categories ].flatten.each do |category|
                xpath = "./g[#{predicate_for category}]"
                group.elements.each(xpath) do |group|
                  classes = group.attributes["class"].to_s.split(?\s)
                  original_id = [ id, *classes, "original" ].join SEGMENT
                  elements = group.elements.map(&:remove)
                  [ *names ].each do |name|
                    group.add_element "use", "xlink:href" => "##{original_id}", "class" => [ name, *classes ].join(?\s)
                  end
                  original = group.add_element("g", "id" => original_id)
                  elements.each do |element|
                    original.elements << element
                  end
                end
              end
            end
          when "samples"
            args.each do |categories, attributes|
              [ categories ].flatten.map do |category|
                [ "./g[#{predicate_for category}]", category]
              end.select do |xpath, category|
                group.elements["#{xpath}//path"]
              end.each do |xpath, category|
                elements = case attributes
                when Array then attributes.map(&:to_a).inject(&:+) || []
                when Hash  then attributes.map(&:to_a)
                end.map { |key, value| { key => value } }
                interval = elements.find { |hash| hash["interval"] }.delete("interval")
                elements.reject!(&:empty?)
                symbol_ids = elements.map.with_index do |element, index|
                  [ id, *category.split(?\s), "symbol", *(index if elements.many?) ].join(SEGMENT).tap do |symbol_id|
                    memo << [ "//svg/defs", { "g" => { "id" => symbol_id } } ]
                    memo << [ "//svg/defs/g[@id='#{symbol_id}']", element ]
                  end
                end
                group.elements.each("#{xpath}//path") do |path|
                  uses = []
                  path.attributes["d"].to_s.split(/ Z| Z M | M |M /).reject(&:empty?).each do |subpath|
                    subpath.split(/ L | C -?[\d\.]+ -?[\d\.]+ -?[\d\.]+ -?[\d\.]+ /).map do |pair|
                      pair.split(?\s).map(&:to_f)
                    end.segments.inject(0.5) do |alpha, segment|
                      angle = 180.0 * segment.difference.angle / Math::PI
                      while alpha * interval < segment.distance
                        segment[0] = segment.along(alpha * interval / segment.distance)
                        translate = segment[0].round(MM_DECIMAL_DIGITS).join ?\s
                        uses << { "use" => {"transform" => "translate(#{translate}) rotate(#{angle.round 2})", "xlink:href" => "##{symbol_ids.sample}" } }
                        alpha = 1.0
                      end
                      alpha - segment.distance / interval
                    end
                  end
                  memo << [ xpath, uses ]
                end
              end
            end
          when "inpoints", "outpoints"
            index = %w[inpoints outpoints].index command
            args.each do |categories, attributes|
              [ categories ].flatten.map do |category|
                [ "./g[#{predicate_for category}]", [ id, *category.split(?\s), command ].join(SEGMENT) ]
              end.select do |xpath, symbol_id|
                group.elements["#{xpath}//path[@fill='none']"]
              end.each do |xpath, symbol_id|
                memo << [ "//svg/defs", { "g" => { "id" => symbol_id } } ]
                memo << [ "//svg/defs/g[@id='#{symbol_id}']", attributes ]
                group.elements.each("#{xpath}//path[@fill='none']") do |path|
                  uses = []
                  path.attributes["d"].to_s.split(/ Z| Z M | M |M /).reject(&:empty?).each do |subpath|
                    subpath.split(/ L | C -?[\d\.]+ -?[\d\.]+ -?[\d\.]+ -?[\d\.]+ /).values_at(0,1,-2,-1).map do |pair|
                      pair.split(?\s).map(&:to_f)
                    end.segments[-index].rotate(index).tap do |segment|
                      angle = 180.0 * segment.difference.angle / Math::PI
                      translate = segment[0].round(MM_DECIMAL_DIGITS).join ?\s
                      uses << { "use" => { "transform" => "translate(#{translate}) rotate(#{angle.round 2})", "xlink:href" => "##{symbol_id}" } }
                    end
                  end
                  memo << [ xpath, uses ]
                end
              end
            end
          when *SVG_PRESENTATION_ATTRIBUTES then memo << [ "self::", { command => args } ]
          when *sublayers
          else
            if args.is_a? Hash
              keys = args.keys & SVG_PRESENTATION_ATTRIBUTES
              values = args.values_at *keys
              svg_args = Hash[keys.zip values]
              [ *command ].each do |category|
                memo << [ "./g[#{predicate_for category}]", svg_args ]
                memo << [ "./g[@class]/use[#{predicate_for category}]", svg_args ]
              end if svg_args.any?
            end
          end
          memo
        end.each.with_index do |(xpath, args), index|
          case args
          when nil
            REXML.each(group, xpath, &:remove)
          when Hash, Array
            REXML::XPath.each(group, xpath) do |node|
              case node
              when REXML::Element
                case args
                when Array then args.map(&:to_a).inject(&:+) || []
                when Hash  then args
                end.each do |key, value|
                  case value
                  when Hash then node.add_element key, value
                  else node.add_attribute key, value
                  end
                end
              end
            end
          else
            REXML::XPath.each(group, xpath) do |node|
              case node
              when REXML::Attribute then node.element.attributes[node.name] = args
              when REXML::Element   then [ *args ].each { |tag| node.add_element tag }
              when REXML::Text      then node.value = args
              end
            end
          end
        end
        until group.elements.each(".//g[not(*)]", &:remove).empty? do
        end
      end
    end
  end
end

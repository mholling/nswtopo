module NSWTopo
  def inspect(url_or_path, sort: nil, **options)
    subdivide = lambda do |items, indent = nil, &block|
      Enumerator.new do |yielder|
        grouped = block[items]
        grouped.each.with_index do |(item, group), index|
          *new_indent, last = indent
          case last
          when "├─ " then new_indent << "│  "
          when "└─ " then new_indent << "   "
          end
          new_indent << case index
          when grouped.size - 1 then "└─ "
          else                       "├─ "
          end if indent
          yielder << [new_indent, item]
          subdivide[group, new_indent, &block].inject(yielder, &:<<)
        end
      end
    end

    source = case url_or_path
    when ArcGIS::Service then ArcGIS::Service.new(url_or_path)
    when Shapefile::Source then Shapefile::Source.new(url_or_path)
    else raise OptionParser::InvalidArgument, url_or_path
    end
    layer = source.layer(**options)

    if fields = options[:fields]
      template = "%#{fields.map(&:size).max}s: %s%s (%i)"
      subdivide[layer.counts] do |counts|
        counts.group_by do |attributes, count|
          attributes.shift
        end.entries.select(&:first).map.with_index do |((name, value), counts), index|
          [name, value, counts.sum(&:last), counts, index]
        end.sort do |(name1, value1, count1, counts1, index1), (name2, value2, count2, counts2, index2)|
          case sort
          when "value" then value1 && value2 ? value1 <=> value2 : value1 ? 1 : value2 ? -1 : 0
          when "count" then count2 <=> count1
          else index1 <=> index2
          end
        end.map do |name, value, count, counts, index|
          [[name, value, count], counts]
        end
      end.each do |indents, (name, value, count)|
        display_value = value.nil? || /[^\w\s-]|[\t\n\r]/ === value ? value.inspect : value
        puts template % [name, indents.join, display_value, count]
      end
    else
      subdivide[layer.info] do |hash|
        hash.map do |key, value|
          Hash === value ? ["#{key}:", value] : ["#{key}: #{value}", []]
        end
      end.each do |indents, info|
        puts indents.join << info
      end
    end

  rescue ArcGIS::Layer::NoLayerError, Shapefile::Layer::NoLayerError
    options.each do |flag, value|
      raise OptionParser::InvalidOption, "--#{flag} requires a layer name"
    end
    subdivide[source.info, &:itself].each do |indents, info|
      puts indents.join << info
    end
  end
end

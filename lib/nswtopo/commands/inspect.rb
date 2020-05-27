module NSWTopo
  def inspect(url_or_path, sort: nil, **options)
    indent = lambda do |items, parts = nil, &block|
      Enumerator.new do |yielder|
        grouped = block[items]
        grouped.each.with_index do |(item, group), index|
          *new_parts, last_part = parts
          case last_part
          when "├─ " then new_parts << "│  "
          when "└─ " then new_parts << "   "
          end
          new_parts << case index
          when grouped.size - 1 then "└─ "
          else                       "├─ "
          end if parts
          yielder << [new_parts, item]
          indent[group, new_parts, &block].inject(yielder, &:<<)
        end
      end
    end

    source = case url_or_path
    when ArcGIS::Service
      ArcGIS::Service.new(url_or_path)
    when Shapefile::Source
      raise OptionParser::InvalidOption, "--id only applies to ArcGIS layers" if options[:id]
      Shapefile::Source.new(url_or_path)
    else
      raise OptionParser::InvalidArgument, url_or_path
    end
    layer = source.layer(**options)

    if fields = options[:fields]
      template = "%#{fields.map(&:size).max}s: %s%s (%i)"
      indent[layer.counts] do |counts|
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
      indent[layer.info] do |hash|
        hash.map do |key, value|
          Hash === value ? ["#{key}:", value] : ["#{key}: #{value}", []]
        end
      end.each do |indents, info|
        puts indents.join << info
      end
    end

  rescue ArcGIS::Layer::NoLayerError, Shapefile::Layer::NoLayerError
    raise OptionParser::InvalidArgument, "specify an ArcGIS layer in URL or with --layer" if options.any?
    indent[source.info, &:itself].each do |indents, info|
      puts indents.join << info
    end
  rescue ArcGIS::Layer::TooManyFieldsError
    raise OptionParser::InvalidOption, "use less fields with --fields"
  end
end

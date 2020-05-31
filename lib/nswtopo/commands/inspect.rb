module NSWTopo
  def inspect(url_or_path, coords: nil, codes: nil, countwise: nil, **options)
    indent = lambda do |items, parts = nil, &block|
      Enumerator.new do |yielder|
        next unless items
        grouped = block ? block.(items) : items
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
          indent.(group, new_parts, &block).inject(yielder, &:<<)
        end
      end
    end

    options[:geometry] = GeoJSON.multipoint(coords).bbox if coords

    source = case url_or_path
    when ArcGIS::Service
      ArcGIS::Service.new(url_or_path)
    when Shapefile::Source
      raise OptionParser::InvalidOption, "--id only applies to ArcGIS layers" if options[:id]
      raise OptionParser::InvalidOption, "--codes only applies to ArcGIS layers" if codes
      Shapefile::Source.new(url_or_path)
    else
      raise OptionParser::InvalidArgument, url_or_path
    end
    layer = source.layer(**options)

    case
    when codes
      %i[where fields decode].each do |flag|
        raise OptionParser::InvalidOption, "can't have --#{flag} with --codes" if options[flag]
      end
      indent.(layer.codes) do |level|
        level.map do |key, values|
          case key
          when Array
            code, value = key
            display_value = value.nil? || /[^\w\s-]|[\t\n\r]/ === value ? value.inspect : value
            ["#{code} → #{display_value}", values]
          else
            ["#{key}:", values]
          end
        end
      end.each do |indents, info|
        puts indents.join << info
      end

    when fields = options[:fields]
      template = "%%%is │ %%%is │ %%s"
      indent.(layer.counts) do |counts|
        counts.group_by do |attributes, count|
          attributes.shift
        end.entries.select(&:first).map do |(name, value), counts|
          [[name, counts.sum(&:last), value], counts]
        end.sort do |((name1, count1, value1), counts1), ((name2, count2, value2), counts2)|
          next count2 <=> count1 if countwise
          value1 && value2 ? value1 <=> value2 : value1 ? 1 : value2 ? -1 : 0
        end
      end.map do |indents, (name, count, value)|
        next name, count.to_s, indents.join << (value.nil? || /[^\w\s-]|[\t\n\r]/ === value ? value.inspect : value.to_s)
      end.transpose.tap do |names, counts, lines|
        template %= [names.map(&:size).max, counts.map(&:size).max] if names
      end.transpose.each do |row|
        puts template % row
      end

    else
      indent.(layer.info) do |hash|
        hash.map do |key, value|
          Hash === value ? ["#{key}:", value] : "#{key}: #{value}"
        end
      end.each do |indents, info|
        puts indents.join << info
      end
    end

  rescue ArcGIS::Layer::NoLayerError, Shapefile::Layer::NoLayerError
    raise OptionParser::InvalidArgument, "specify an ArcGIS layer in URL or with --layer" if codes || sort || options.any?
    indent.("layers:" => source.layer_info).each do |indents, info|
      puts indents.join << info
    end
  rescue ArcGIS::Renderer::TooManyFieldsError
    raise OptionParser::InvalidOption, "use less fields with --fields"
  end
end

module NSWTopo
  def inspect(url_or_path, coords: nil, codes: nil, countwise: nil, **options)
    options[:geometry] = GeoJSON.multipoint(coords).bbox if coords

    case url_or_path
    when ArcGIS::Service
      source = ArcGIS::Service.new(url_or_path)
    when Shapefile::Source
      raise OptionParser::InvalidOption, "--id only applies to ArcGIS layers" if options[:id]
      raise OptionParser::InvalidOption, "--decode only applies to ArcGIS layers" if options[:decode]
      raise OptionParser::InvalidOption, "--codes only applies to ArcGIS layers" if codes
      source = Shapefile::Source.new(url_or_path)
      options[:layer] ||= source.only_layer if countwise || options.any?
    else
      raise OptionParser::InvalidArgument, url_or_path
    end
    layer = source.layer(**options)

    case
    when codes
      TreeIndenter.new(layer.codes) do |level|
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
      TreeIndenter.new(layer.counts) do |counts|
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
      TreeIndenter.new(layer.info) do |hash|
        hash.map do |key, value|
          Hash === value ? ["#{key}:", value] : "#{key}: #{value}"
        end
      end.each do |indents, info|
        puts indents.join << info
      end
    end

  rescue ArcGIS::Layer::NoLayerError, Shapefile::Layer::NoLayerError => error
    raise OptionParser::MissingArgument, error.message if codes || countwise || options.any?
    puts "layers:"
    TreeIndenter.new(source.layer_info, []).each do |indents, info|
      puts indents.join << info
    end
  rescue ArcGIS::Renderer::TooManyFieldsError
    raise OptionParser::InvalidOption, "use less fields with --fields"
  end
end

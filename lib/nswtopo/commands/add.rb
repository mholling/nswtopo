module NSWTopo
  def add(archive, *layers, after: nil, before: nil, replace: nil, overwrite: false, **options)
    create_options = {
      after: Layer.sanitise(after),
      before: Layer.sanitise(before),
      replace: Layer.sanitise(replace),
      overwrite: overwrite
    }
    map = Map.load archive

    Enumerator.new do |yielder|
      while layers.any?
        layer, basedir = layers.shift
        path = Pathname(layer).expand_path(*basedir)
        case layer
        when /^controls\.(gpx|kml)$/i
          yielder << [path.basename(path.extname).to_s, "type" => "Control", "path" => path]
        when /\.(gpx|kml)$/i
          yielder << [path.basename(path.extname).to_s, "type" => "Overlay", "path" => path]
        when /\.(tiff?|png|jpg)$/i
          yielder << [path.basename(path.extname).to_s, "type" => "Import", "path" => path]
        when "contours"
          yielder << [layer, "type" => "Contour"]
        when "spot-heights"
          yielder << [layer, "type" => "Spot"]
        when "relief"
          yielder << [layer, "type" => "Relief"]
        when "grid"
          yielder << [layer, "type" => "Grid"]
        when "declination"
          yielder << [layer, "type" => "Declination"]
        when "controls"
          yielder << [layer, "type" => "Control"]
        when /\.yml$/i
          basedir ||= path.parent
          raise "couldn't find '#{layer}'" unless path.file?
          case contents = YAML.load(path.read)
          when Array
            contents.reverse.map do |item|
              Pathname(item.to_s)
            end.each do |relative_path|
              raise "#{relative_path} is not a relative path" unless relative_path.relative?
              layers.prepend [Pathname(relative_path).expand_path(path.parent).relative_path_from(basedir).to_s, basedir]
            end
          when Hash
            name = path.sub_ext("").relative_path_from(basedir).descend.map(&:basename).join(?.)
            yielder << [name, contents.merge("source" => path)]
          else
            raise "couldn't parse #{path}"
          end
        else
          path = Pathname("#{layer}.yml")
          raise "#{layer} is not a relative path" unless path.relative?
          basedir ||= layer_dirs.find do |root|
            path.expand_path(root).file?
          end
          layers.prepend [path.to_s, basedir]
        end
      end
    rescue YAML::Exception
      raise "couldn't parse #{path}"
    end.map do |name, params|
      params.merge! options.transform_keys(&:to_s)
      params.merge! Config[name] if Config[name]
      Layer.new(name, map, params)
    end.tap do |layers|
      raise OptionParser::MissingArgument, "no layers specified" unless layers.any?
      unless layers.one?
        raise OptionParser::InvalidArgument, "can't specify opacity when adding multiple layers" if options[:opacity]
        raise OptionParser::InvalidArgument, "can't specify data path when adding multiple layers" if options[:path]
      end
      map.add *layers, create_options
    end
  end

  def contours(archive, dem_path, **options)
    add archive, "contours", **options, path: Pathname(dem_path)
  end

  def spot_heights(archive, dem_path, **options)
    add archive, "spot-heights", **options, path: Pathname(dem_path)
  end

  def relief(archive, dem_path, **options)
    add archive, "relief", **options, path: Pathname(dem_path)
  end

  def grid(archive, **options)
    add archive, "grid", **options
  end

  def declination(archive, **options)
    add archive, "declination", **options
  end

  def controls(archive, gps_path, **options)
    raise OptionParser::InvalidArgument, gps_path unless gps_path =~ /\.(gpx|kml)$/i
    add archive, "controls", **options, path: Pathname(gps_path)
  end

  def overlay(archive, gps_path, **options)
    raise OptionParser::InvalidArgument, gps_path unless gps_path =~ /\.(gpx|kml)$/i
    add archive, gps_path, **options, path: Pathname(gps_path)
  end
end

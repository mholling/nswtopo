module NSWTopo
  def config(layer = nil, **options)
    path, resolution = options[:path], options[:resolution]
    layer = Layer.sanitise layer

    case
    when !layer
      raise OptionParser::InvalidArgument, "no layer name specified for path" if path
      raise OptionParser::InvalidArgument, "no layer name specified for resolution" if resolution
    when path || resolution
      Config.store layer, "path", path.to_s if path
      Config.store layer, "resolution", resolution if resolution
    end

    options.each do |key, value|
      case key
      when :chrome
        raise "chrome path is not an executable" unless value.executable? && !value.directory?
        Config.store key.to_s, value.to_s
      when :"layer-dir"
        raise "not a directory: %s" % value unless value.directory?
        Config.store key.to_s, value.to_s
      when *%i[labelling debug gpu versioning zlib-level knockout]
        Config.store key.to_s, value
      when :delete
        Config.delete *layer, value
      end
    end

    if options.empty?
      puts Config.to_str.each_line.drop(1)
      log_neutral "no configuration yet" if Config.empty?
    else
      Config.save
      log_success "configuration updated"
    end
  end
end

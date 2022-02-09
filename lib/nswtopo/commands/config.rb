module NSWTopo
  def config(layer = nil, **options)
    chrome, path, resolution, layer_dir, labelling, zlib_level, delete = options.values_at :chrome, :path, :resolution, :"layer-dir", :labelling, :"zlib-level", :delete
    raise "not a directory: %s" % layer_dir if layer_dir && !layer_dir.directory?
    raise "chrome path is not an executable" if chrome && !chrome.executable?
    Config.store("chrome", chrome.to_s) if chrome
    Config.store("labelling", labelling) unless labelling.nil?
    Config.store("layer-dir", layer_dir.to_s) if layer_dir
    Config.store("zlib-level", zlib_level) if zlib_level

    layer = Layer.sanitise layer
    case
    when !layer
      raise OptionParser::InvalidArgument, "no layer name specified for path" if path
      raise OptionParser::InvalidArgument, "no layer name specified for resolution" if resolution
    when path || resolution
      Config.store(layer, "path", path.to_s) if path
      Config.store(layer, "resolution", resolution) if resolution
    end
    Config.delete(*layer, delete) if delete

    if options.empty?
      puts Config.to_str.each_line.drop(1)
      log_neutral "no configuration yet" if Config.empty?
    else
      Config.save
      log_success "configuration updated"
    end
  end
end

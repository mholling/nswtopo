module NSWTopo
  module Config
    include Log

    def self.method_missing(symbol, *args, &block)
      extend(self).init
      singleton_class.remove_method :method_missing
      send symbol, *args, &block
    end

    def init
      candidates = []
      %w[XDG_CONFIG_HOME APPDATA].each do |key|
        candidates << [ENV.fetch(key), "nswtopo"]
      rescue KeyError
      end
      candidates << [Dir.home, "Library", "Application Support", "com.nswtopo"]
      candidates << [Dir.home, ".config", "nswtopo"]
      candidates << [Dir.home, ".nswtopo"]

      config_dir = candidates.map do |base, *parts|
        Pathname(base).join(*parts)
      end.first do |dir|
        dir.parent.directory?
      end

      @user, @local = paths = [config_dir, Pathname.pwd].map do |directory|
        directory / "nswtopo.cfg"
      end

      @config = paths.map do |path|
        load path
      end.grep(Hash).inject({}, &:deep_merge)
    end

    def load(path)
      YAML.load(path.read) if path.file?
    rescue YAML::Exception
      log_warn "couldn't parse #{path} - ignoring"
    end

    extend Forwardable
    delegate %i[[] fetch] => :@config

    def update(layer = nil, chrome: nil, firefox: nil, path: nil, resolution: nil, list: false, delete: false, local: false)
      layer = Layer.sanitise layer
      config_path = local ? @local : @user
      config = load(config_path) || {}

      raise "chrome path is not an executable" if chrome && !chrome.executable?
      raise "firefox path is not an executable" if firefox && !firefox.executable?
      config["chrome"] = chrome.to_s if chrome
      config["firefox"] = firefox.to_s if firefox

      case
      when !layer
        raise OptionParser::InvalidArgument, "no layer name specified for path" if path
        raise OptionParser::InvalidArgument, "no layer name specified for resolution" if resolution
      when path || resolution
        config[layer] ||= {}
        config[layer]["path"] = path.to_s if path
        config[layer]["resolution"] = resolution if resolution
      end

      case
      when !delete
      when !layer
        config.delete(delete) || raise("no such setting: %s" % delete)
      when Hash === config[layer]
        config[layer].delete(delete) || raise("no such setting: %s" % delete)
        config.delete(layer) if config[layer].empty?
      else
        raise "no such layer: %s" % layer
      end

      if path || resolution || chrome || firefox || delete
        config_path.parent.mkpath
        config_path.write config.to_yaml
        log_success "configuration updated"
      end

      case
      when !list
      when config_path.file? then puts config_path.each_line.drop(1)
      when local then log_neutral "no configuration in this directory"
      else            log_neutral "no configuration yet"
      end
    end

    def with_browser
      browser_name = %w[chrome firefox].find &@config.method(:key?)
      raise "please configure a path for google chrome" unless browser_name
      browser_path = Pathname.new @config[browser_name]
      yield browser_name, browser_path
    rescue Errno::ENOENT
      raise "invalid %s path: %s" % [browser_name, browser_path]
    end
  end
end

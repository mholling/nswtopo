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

      @path = config_dir = candidates.map do |base, *parts|
        Pathname(base).join(*parts)
      end.first do |dir|
        dir.parent.directory?
      end.join("nswtopo.cfg")

      @config = begin
        @path.file? ? YAML.load(@path.read) : Hash[]
      rescue YAML::Exception
        log_warn "couldn't parse #{path} - ignoring"
        Hash[]
      end
    end

    extend Forwardable
    delegate %i[[] fetch] => :@config

    def update(layer = nil, chrome: nil, firefox: nil, path: nil, resolution: nil, list: false, delete: false)
      layer = Layer.sanitise layer

      raise "chrome path is not an executable" if chrome && !chrome.executable?
      raise "firefox path is not an executable" if firefox && !firefox.executable?
      @config["chrome"] = chrome.to_s if chrome
      @config["firefox"] = firefox.to_s if firefox

      case
      when !layer
        raise OptionParser::InvalidArgument, "no layer name specified for path" if path
        raise OptionParser::InvalidArgument, "no layer name specified for resolution" if resolution
      when path || resolution
        @config[layer] ||= {}
        @config[layer]["path"] = path.to_s if path
        @config[layer]["resolution"] = resolution if resolution
      end

      case
      when !delete
      when !layer
        @config.delete(delete) || raise("no such setting: %s" % delete)
      when Hash === @config[layer]
        @config[layer].delete(delete) || raise("no such setting: %s" % delete)
        @config.delete(layer) if @config[layer].empty?
      else
        raise "no such layer: %s" % layer
      end

      if path || resolution || chrome || firefox || delete
        @path.parent.mkpath
        @path.write @config.to_yaml
        log_success "configuration updated"
      end

      return unless list
      puts @config.to_yaml.each_line.drop(1)
      log_neutral "no configuration yet" if @config.empty?
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

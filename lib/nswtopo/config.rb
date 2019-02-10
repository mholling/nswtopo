module NSWTopo
  module Config
    include Log
    singleton_class.attr_writer :extra_path

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

      @path = candidates.map do |base, *parts|
        Pathname(base).join(*parts)
      end.first do |dir|
        dir.parent.directory?
      end.join("nswtopo.cfg")

      @config, extra = [@path, @extra_path].map do |path|
        next Hash[] unless path&.file?
        config = YAML.load(path.read)
        Hash === config ? config : raise
      rescue YAML::Exception, RuntimeError
        log_warn "couldn't parse #{path} - ignoring"
        Hash[]
      end

      @merged = @config.deep_merge extra
    end

    def store(*entries, key, value)
      entries.inject(@config) do |config, entry|
        config[entry] ||= {}
        Hash === config[entry] ? config[entry] : raise("entry already taken: %s" % entry)
      end.store key, value
    end

    def delete(*entries, key)
      delete_recursive @config, *entries, key
    end

    def delete_recursive(config, *entries, key)
      case
      when entry = entries.shift
        raise "no such entry: %s" % entry unless Hash === config[entry]
        delete_recursive config[entry], *entries, key
        config.delete entry if config[entry].empty?
      when config.key?(key)
        config.delete key
      else
        raise "no such entry: %s" % key
      end
    end

    extend Forwardable
    delegate %i[slice empty? [] fetch] => :@merged
    def_delegator :@config, :to_yaml, :to_str

    def save
      @path.parent.mkpath
      @path.write @config.to_yaml
    end
  end
end

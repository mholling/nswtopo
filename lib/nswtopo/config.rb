module NSWTopo
  class Config
    BASE_CONFIG = %Q[
      name: map
      scale: 25000
      ppi: 300
      rotation: 0
    ]

    def initialize
      @config = YAML.load BASE_CONFIG
    end

    def finalise(extra_config)
      %w[bounds.kml bounds.gpx].map do |filename|
        Pathname.pwd + filename
      end.find(&:exist?).tap do |bounds_path|
        @config["bounds"] = bounds_path if bounds_path
      end

      @config = [ Pathname.new(__dir__).parent.parent, Pathname.pwd ].map do |dir_path|
        dir_path + "nswtopo.cfg"
      end.select(&:exist?).map do |config_path|
        begin
          YAML.load config_path.read
        rescue ArgumentError, SyntaxError => e
          abort "Error in configuration file: #{e.message}"
        end
      end.push(extra_config).inject(@config, &:deep_merge)

      @config["include"] = [ *@config["include"] ]
      if @config["include"].empty?
        @config["include"] << "nsw/topographic"
        puts "No layers specified. Adding nsw/topographic by default."
      end

      @config["exclude"] = [ *@config["exclude"] ].map do |name|
        name.gsub ?/, SEGMENT
      end

      %w[controls.gpx controls.kml].map do |filename|
        Pathname.pwd + filename
      end.find(&:file?).tap do |control_path|
        if control_path
          @config["include"] |= [ "controls" ]
          @config["controls"] ||= {}
          @config["controls"]["path"] ||= control_path.to_s
        end
      end

      @config["include"].unshift "canvas" if Pathname.new("canvas.png").expand_path.exist?

      @map = Map.new @config
      @config.freeze
    end

    def [](name)
      @config[name]
    end

    def keys
      @config.keys
    end

    def values_at(*args)
      @config.values_at *args
    end

    attr_reader :map
  end
end
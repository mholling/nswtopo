require 'date'
require 'open3'
require 'uri'
require 'net/http'
require 'rexml/document'
require 'rexml/formatters/pretty'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require 'pathname'
require 'json'
require 'base64'
require 'set'
require 'etc'
require 'timeout'
require 'ostruct'
require 'forwardable'
require 'rubygems/package'
require 'zlib'
begin
  require 'pty'
  require 'expect'
rescue LoadError
end

require_relative 'nswtopo/helpers'
require_relative 'nswtopo/avl_tree'
require_relative 'nswtopo/geometry'
require_relative 'nswtopo/log'
require_relative 'nswtopo/safely'
require_relative 'nswtopo/os'
require_relative 'nswtopo/dither'
require_relative 'nswtopo/zip'
require_relative 'nswtopo/font'
require_relative 'nswtopo/archive'
require_relative 'nswtopo/gis'
require_relative 'nswtopo/tiled_web_map'
require_relative 'nswtopo/formats'
require_relative 'nswtopo/map'
require_relative 'nswtopo/layer'
require_relative 'nswtopo/version'
require_relative 'nswtopo/config'
require_relative 'nswtopo/commands'

module NSWTopo
  PartialFailureError = Class.new RuntimeError
  extend self, Log

  def init(archive, options)
    puts Map.init(archive, options)
  end

  def layer_dirs
    @layer_dirs ||= Array(Config["layer-dir"]).map(&Pathname.method(:new)) << Pathname.pwd
  end

  def info(archive, options)
    raise OptionParser::InvalidArgument, "one output option only" if options.slice(:json, :proj).length > 1
    puts Map.load(archive).info(options)
  end

  def add(archive, *layers, options)
    create_options = {
      after: Layer.sanitise(options.delete :after),
      before: Layer.sanitise(options.delete :before),
      replace: Layer.sanitise(options.delete :replace),
      overwrite: options.delete(:overwrite)
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
        raise OptionParser::InvalidArgument, "can't specify resolution when adding multiple layers" if options[:resolution]
        raise OptionParser::InvalidArgument, "can't specify data path when adding multiple layers" if options[:path]
      end
      map.add *layers, create_options
    end
  end

  def contours(archive, dem_path, options)
    add archive, "contours", options.merge(path: Pathname(dem_path))
  end

  def spot_heights(archive, dem_path, options)
    add archive, "spot-heights", options.merge(path: Pathname(dem_path))
  end

  def relief(archive, dem_path, options)
    add archive, "relief", options.merge(path: Pathname(dem_path))
  end

  def grid(archive, options)
    add archive, "grid", options
  end

  def declination(archive, options)
    add archive, "declination", options
  end

  def controls(archive, gps_path, options)
    add archive, "controls", options.merge(path: Pathname(gps_path))
  end

  def overlay(archive, gps_path, options)
    raise OptionParser::InvalidArgument, gps_path unless gps_path =~ /\.(gpx|kml)$/i
    add archive, gps_path, options.merge(path: Pathname(gps_path))
  end

  def delete(archive, *names, options)
    map = Map.load archive
    names.map do |name|
      Layer.sanitise name
    end.uniq.map do |name|
      name[?*] ? %r[^#{name.gsub(?., '\.').gsub(?*, '.*')}$] : name
    end.tap do |names|
      map.delete *names
    end
  end

  def render(archive, *formats, options)
    overwrite = options.delete :overwrite
    formats << "svg" if formats.empty?
    formats.map do |format|
      Pathname(Formats === format ? "#{archive.basename}.#{format}" : format)
    end.uniq.each do |path|
      format = path.extname.delete_prefix(?.)
      raise "unrecognised format: #{path}" if format.empty?
      raise "unrecognised format: #{format}" unless Formats === format
      raise "file already exists: #{path}" if path.exist? && !overwrite
      raise "non-existent directory: #{path.parent}" unless path.parent.directory?
    end.tap do |paths|
      Map.load(archive).render *paths, options
    end
  end

  def with_browser
    browser_name, browser_path = Config.slice("chrome", "firefox").first
    raise "please configure a path for google chrome" unless browser_name
    yield browser_name, Pathname.new(browser_path)
  rescue Errno::ENOENT
    raise "invalid %s path: %s" % [browser_name, browser_path]
  end
end

begin
  require 'nswtopo/layers'
rescue LoadError
end

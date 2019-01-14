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
require 'rbconfig'
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

require_relative 'helpers'
require_relative 'avl_tree'
require_relative 'geometry'
require_relative 'nswtopo/helpers'
require_relative 'nswtopo/gis'
require_relative 'nswtopo/formats'
require_relative 'nswtopo/map'
require_relative 'nswtopo/layer'
require_relative 'nswtopo/version'

module NSWTopo
  PartialFailureError = Class.new RuntimeError
  extend self

  def init(archive, config, options)
    puts Map.init(archive, config, options)
  end

  def info(archive, config, options)
    puts Map.load(archive, config).info(options)
  end

  def add(archive, config, *layers, options)
    create_options = {
      after: Layer.sanitise(options.delete :after),
      before: Layer.sanitise(options.delete :before),
      overwrite: options.delete(:overwrite)
    }
    map = Map.load archive, config
    # TODO: iterate separately for each layer, rather than in combination, so we keep default ordering
    Enumerator.new do |yielder|
      while layers.any?
        layer, basedir = layers.shift
        path = Pathname(layer).expand_path(*basedir)
        case layer
        when /^controls\.(gpx|kml)$/i
          yielder << [ path.basename(path.extname).to_s, "type" => "Control", "path" => path ]
        when /\.(gpx|kml)$/i
          yielder << [ path.basename(path.extname).to_s, "type" => "Overlay", "path" => path ]
        when /\.(tiff?|png|jpg)$/i
          yielder << [ path.basename(path.extname).to_s, "type" => "Import", "path" => path ]
        when "grid"
          yielder << [ layer.downcase, "type" => "Grid" ]
        when "declination"
          yielder << [ layer.downcase, "type" => "Declination" ]
        when /\.yml$/i
          basedir ||= path.parent
          raise "couldn't find '#{layer}'" unless path.file?
          case contents = YAML.load(path.read)
          when Array
            contents.reverse.map do |item|
              Pathname(item.to_s)
            end.each do |relative_path|
              raise "#{relative_path} is not a relative path" unless relative_path.relative?
              layers.prepend [ Pathname(relative_path).expand_path(path.parent).relative_path_from(basedir).to_s, basedir ]
            end
          when Hash
            name = path.sub_ext("").relative_path_from(basedir).descend.map(&:basename).join(?.)
            yielder << [ name, contents.merge("source" => path) ]
          else
            raise "couldn't parse #{path}"
          end
        else
          path = Pathname("#{layer}.yml")
          raise "#{layer} is not a relative path" unless path.relative?
          basedir ||= [ Pathname.pwd, Pathname(__dir__).parent / "layers" ].find do |root|
            path.expand_path(root).file?
          end
          layers.prepend [ path.to_s, basedir ]
        end
      end
    rescue YAML::Exception
      raise "couldn't parse #{path}"
    end.map do |name, params|
      params.merge! options.transform_keys(&:to_s)
      params.merge! config[name] if config[name]
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

  def grid(archive, config, options)
    add archive, config, "grid", options
  end

  def declination(archive, config, options)
    add archive, config, "declination", options
  end

  def remove(archive, config, *names, options)
    map = Map.load archive, config
    names.uniq.map do |name|
      Layer.sanitise name
    end.map do |name|
      name[?*] ? %r[^#{name.gsub(?., '\.').gsub(?*, '.*')}$] : name
    end.tap do |names|
      map.remove *names
    end
  end

  def render(archive, config, *formats, options)
    overwrite = options.delete :overwrite
    formats.map do |format|
      Pathname(Formats === format ? "#{archive.basename}.#{format}" : format)
    end.uniq.each do |path|
      format = path.extname.delete_prefix(?.)
      raise "unrecognised format: #{path}" if format.empty?
      raise "unrecognised format: #{format}" unless Formats === format
      raise "file already exists: #{path}" if path.exist? && !overwrite
      raise "non-existent directory: #{path.parent}" unless path.parent.directory?
    end.tap do |paths|
      raise OptionParser::MissingArgument, "no output formats specified" unless paths.any?
      Map.load(archive, config).render *paths, options
    end
  end

  def layers(state: nil, root: nil, indent: state ? "#{state}/" : "")
    directory = [ Pathname(__dir__).parent, "layers", *state ].inject(&:/)
    root ||= directory
    directory.children.sort.each do |path|
      case
      when path.directory?
        puts [ indent, path.relative_path_from(root) ].join
        layers state: [ *state, path.basename ], root: root, indent: "  " + indent
      when path.sub_ext("").directory?
      when path.extname == ".yml"
        puts [ indent, path.relative_path_from(root).sub_ext("") ].join
      end
    end
  end
end

# # TODO: re-implement intervals-contours? (a better way?):
# CONFIG["contour-interval"].tap do |interval|
#   interval ||= CONFIG.map.scale < 40000 ? 10 : 20
#   layers.each do |name, klass, params|
#     params["exclude"] = [ *params["exclude"] ]
#     [ *params["intervals-contours"] ].select do |candidate, sublayers|
#       candidate != interval
#     end.map(&:last).each do |sublayers|
#       params["exclude"] += [ *sublayers ]
#     end
#   end
# end

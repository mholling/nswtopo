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

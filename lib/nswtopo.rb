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

  def layer_dirs
    @layer_dirs ||= Array(Config["layer-dir"]).map(&Pathname.method(:new)) << Pathname.pwd
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

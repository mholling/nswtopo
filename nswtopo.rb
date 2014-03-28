#!/usr/bin/env ruby

# Copyright 2011, 2012 Matthew Hollingworth
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

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
require 'open-uri'

# %w[uri net/http rexml/document rexml/formatters/pretty tmpdir yaml fileutils pathname rbconfig json base64 open-uri].each { |file| require file }

GITHUB_SOURCES = "https://raw.github.com/mholling/nswtopo/master/sources/"

class REXML::Element
  alias_method :unadorned_add_element, :add_element
  def add_element(name, attrs = {})
    unadorned_add_element(name, attrs).tap do |element|
      yield element if block_given?
    end
  end
end

module HashHelpers
  def deep_merge(hash)
    hash.inject(self.dup) do |result, (key, value)|
      result.merge(key => result[key].is_a?(Hash) && value.is_a?(Hash) ? result[key].deep_merge(value) : value)
    end
  end
  
  def deep_merge!(hash)
    hash.each do |key, value|
      self[key].is_a?(Hash) && value.is_a?(Hash) ? self[key].deep_merge!(value) : self[key] = value
    end
    self
  end

  def to_query
    map { |key, value| "#{key}=#{value}" }.join ?&
  end
end
Hash.send :include, HashHelpers

class Dir
  def self.mktmppath
    mktmpdir do |path|
      yield Pathname.new(path)
    end
  end
end

module Enumerable
  def with_progress_interactive(message = nil, indent = 0, timed = true)
    bars = 65 - 2 * indent
    container = "  " * indent + "  [%s]%-7s"
    
    puts "  " * indent + message if message
    Enumerator.new do |yielder|
      $stdout << container % [ (?\s * bars), "" ]
      each_with_index.inject([ Time.now ]) do |times, (object, index)|
        yielder << object
        times << Time.now
        
        filled = (index + 1) * bars / length
        progress_bar = (?- * filled) << (?\s * (bars - filled))
        
        median = [ times[1..-1], times[0..-2] ].transpose.map { |interval| interval.inject(&:-) }.median
        elapsed = times.last - times.first
        remaining = (length + 1 - times.length) * median
        timer = case
        when !timed then ""
        when times.length < 6 then ""
        when elapsed + remaining < 60 then ""
        when remaining < 60   then " -%is" % remaining
        when remaining < 600  then " -%im%02is" % [ (remaining / 60), remaining % 60 ]
        when remaining < 3600 then " -%im" % (remaining / 60)
        else " -%ih%02im" % [ remaining / 3600, (remaining % 3600) / 60 ]
        end
        
        $stdout << "\r" << container % [ progress_bar, timer ]
        times
      end
      
      $stdout << "\r" << container % [ (?- * bars), "" ]
      puts
    end
  end
  
  def with_progress_scripted(message = nil, *args)
    puts message if message
    Enumerator.new(self.each)
  end
  
  alias_method :with_progress, File.identical?(__FILE__, $0) ? :with_progress_interactive : :with_progress_scripted

  def recover(*exceptions)
    Enumerator.new do |yielder|
      each do |element|
        begin
          yielder.yield element
        rescue *exceptions => e
          $stderr.puts "\nError: #{e.message}"
          next
        end
      end
    end
  end
end

class Array
  def median
    sort[length / 2]
  end
  
  def rotate_by(angle)
    cos = Math::cos(angle)
    sin = Math::sin(angle)
    [ self[0] * cos - self[1] * sin, self[0] * sin + self[1] * cos ]
  end

  def rotate_by!(angle)
    self[0], self[1] = rotate_by(angle)
  end
  
  def plus(other)
    [ self, other ].transpose.map { |values| values.inject(:+) }
  end

  def minus(other)
    [ self, other ].transpose.map { |values| values.inject(:-) }
  end

  def dot(other)
    [ self, other ].transpose.map { |values| values.inject(:*) }.inject(:+)
  end

  def norm
    Math::sqrt(dot self)
  end

  def proj(other)
    dot(other) / other.norm
  end
  
  def one_or_many(&block)
    case first
    when Numeric then block.(self)
    else map(&block)
    end
  end
end

module NSWTopo
  SEGMENT = ?.
  
  EARTH_RADIUS = 6378137.0
  
  WINDOWS = !RbConfig::CONFIG["host_os"][/mswin|mingw/].nil?
  OP = WINDOWS ? '(' : '\('
  CP = WINDOWS ? ')' : '\)'
  ZIP = WINDOWS ? "7z a -tzip" : "zip"
  DISCARD_STDERR = WINDOWS ? "2> nul" : "2>/dev/null"
  
  CONFIG = %q[---
name: map
scale: 25000
ppi: 300
rotation: 0
margin: 15
]
  
  module BoundingBox
    def self.convex_hull(points)
      seed = points.inject do |point, candidate|
        point[1] > candidate[1] ? candidate : point[1] < candidate[1] ? point : point[0] < candidate[0] ? point : candidate
      end
  
      sorted = points.reject do |point|
        point == seed
      end.sort_by do |point|
        vector = point.minus seed
        vector[0] / vector.norm
      end
      sorted.unshift seed
  
      result = [ seed, sorted.pop ]
      while sorted.length > 1
        u = sorted[-2].minus result.last
        v = sorted[-1].minus result.last
        if u[0] * v[1] >= u[1] * v[0]
          sorted.pop
          sorted << result.pop
        else
          result << sorted.pop 
        end
      end
      result
    end

    def self.minimum_bounding_box(points)
      polygon = convex_hull(points)
      indices = [ [ :min_by, :max_by ], [ 0, 1 ] ].inject(:product).map do |min, axis|
        polygon.map.with_index.send(min) { |point, index| point[axis] }.last
      end
      calipers = [ [ 0, -1 ], [ 1, 0 ], [ 0, 1 ], [ -1, 0 ] ]
      rotation = 0.0
      candidates = []
  
      while rotation < Math::PI / 2
        edges = indices.map do |index|
          polygon[(index + 1) % polygon.length].minus polygon[index]
        end
        angle, which = [ edges, calipers ].transpose.map do |edge, caliper|
          Math::acos(edge.dot(caliper) / edge.norm)
        end.map.with_index.min_by { |angle, index| angle }
    
        calipers.each { |caliper| caliper.rotate_by!(angle) }
        rotation += angle
    
        break if rotation >= Math::PI / 2
    
        dimensions = [ 0, 1 ].map do |offset|
          polygon[indices[offset + 2]].minus(polygon[indices[offset]]).proj(calipers[offset + 1])
        end
    
        centre = polygon.values_at(*indices).map do |point|
          point.rotate_by(-rotation)
        end.partition.with_index do |point, index|
          index.even?
        end.map.with_index do |pair, index|
          0.5 * pair.map { |point| point[index] }.inject(:+)
        end.rotate_by(rotation)
    
        if rotation < Math::PI / 4
          candidates << [ centre, dimensions, rotation ]
        else
          candidates << [ centre, dimensions.reverse, rotation - Math::PI / 2 ]
        end
    
        indices[which] += 1
        indices[which] %= polygon.length
      end
  
      candidates.min_by { |centre, dimensions, rotation| dimensions.inject(:*) }
    end
  end

  module WorldFile
    def self.write(topleft, resolution, angle, path)
      path.open("w") do |file|
        file.puts  resolution * Math::cos(angle * Math::PI / 180.0)
        file.puts  resolution * Math::sin(angle * Math::PI / 180.0)
        file.puts  resolution * Math::sin(angle * Math::PI / 180.0)
        file.puts -resolution * Math::cos(angle * Math::PI / 180.0)
        file.puts topleft.first + 0.5 * resolution
        file.puts topleft.last - 0.5 * resolution
      end
    end
  end
  
  class GPS
    module GPX
      def waypoints
        Enumerator.new do |yielder|
          @xml.elements.each "/gpx//wpt" do |waypoint|
            coords = [ "lon", "lat" ].map { |name| waypoint.attributes[name].to_f }
            name = waypoint.elements["./name"]
            yielder << [ coords, name ? name.text : "" ]
          end
        end
      end
      
      def tracks
        Enumerator.new do |yielder|
          @xml.elements.each "/gpx//trk" do |track|
            list = track.elements.collect(".//trkpt") { |point| [ "lon", "lat" ].map { |name| point.attributes[name].to_f } }
            name = track.elements["./name"]
            yielder << [ list, name ? name.text : "" ]
          end
        end
      end
      
      def areas
        Enumerator.new { |yielder| }
      end
    end

    module KML
      def waypoints
        Enumerator.new do |yielder|
          @xml.elements.each "/kml//Placemark[.//Point/coordinates]" do |waypoint|
            coords = waypoint.elements[".//Point/coordinates"].text.split(',')[0..1].map(&:to_f)
            name = waypoint.elements["./name"]
            yielder << [ coords, name ? name.text : "" ]
          end
        end
      end
      
      def tracks
        Enumerator.new do |yielder|
          @xml.elements.each "/kml//Placemark[.//LineString//coordinates]" do |track|
            list = track.elements[".//LineString//coordinates"].text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) }
            name = track.elements["./name"]
            yielder << [ list, name ? name.text : "" ]
          end
        end
      end
      
      def areas
        Enumerator.new do |yielder|
          @xml.elements.each "/kml//Placemark[.//Polygon//coordinates]" do |polygon|
            list = polygon.elements[".//Polygon//coordinates"].text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) }
            name = polygon.elements["./name"]
            yielder << [ list, name ? name.text : "" ]
          end
        end
      end
    end

    def initialize(path)
      @xml = REXML::Document.new(path.read)
      case
      when @xml.elements["/gpx"] then class << self; include GPX; end
      when @xml.elements["/kml"] then class << self; include KML; end
      else raise BadGpxKmlFile.new(path.to_s)
      end
    rescue REXML::ParseException, Errno::ENOENT
      raise BadGpxKmlFile.new(path.to_s)
    end
  end
  
  class Projection
    def initialize(string)
      @string = string
    end
    
    %w[proj4 wkt wkt_simple wkt_noct wkt_esri mapinfo xml].map do |format|
      [ format, "@#{format}" ]
    end.map do |format, variable|
      define_method format do
        instance_variable_get(variable) || begin
          instance_variable_set variable, %x[gdalsrsinfo -o #{format} "#{@string}"].split(/['\r\n]+/).map(&:strip).join("")
        end
      end
    end
    
    alias_method :to_s, :proj4
    
    %w[central_meridian scale_factor].each do |parameter|
      define_method parameter do
        /PARAMETER\["#{parameter}",([\d\.]+)\]/.match(wkt) { |match| match[1].to_f }
      end
    end
    
    def self.utm(zone, south = true)
      new("+proj=utm +zone=#{zone}#{' +south' if south} +ellps=WGS84 +datum=WGS84 +units=m +no_defs")
    end
    
    def self.wgs84
      new("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")
    end
    
    def self.transverse_mercator(central_meridian, scale_factor)
      new("+proj=tmerc +lat_0=0.0 +lon_0=#{central_meridian} +k=#{scale_factor} +x_0=500000.0 +y_0=10000000.0 +ellps=WGS84 +datum=WGS84 +units=m")
    end
    
    def reproject_to(target, point_or_points)
      case point_or_points.first
      when Array
        echoes = point_or_points.map { |point| "echo #{point.join ?\s}" }.join " && "
        %x[(#{echoes}) | gdaltransform -s_srs "#{self}" -t_srs "#{target}"].each_line.map do |line|
          line.split(?\s)[0..1].map(&:to_f)
        end
      else %x[echo #{point_or_points.join ?\s} | gdaltransform -s_srs "#{self}" -t_srs "#{target}"].split(?\s)[0..1].map(&:to_f)
      end
    end
    
    def reproject_to_wgs84(point_or_points)
      reproject_to Projection.wgs84, point_or_points
    end
    
    def transform_bounds_to(target, bounds)
      reproject_to(target, bounds.inject(&:product)).transpose.map { |coords| [ coords.min, coords.max ] }
    end
  end
  
  class Map
    def initialize(config)
      @name, @scale = config.values_at("name", "scale")
      
      wgs84_points = case
      when config["zone"] && config["eastings"] && config["northings"]
        utm = Projection.utm(config["zone"])
        utm.reproject_to_wgs84 config.values_at("eastings", "northings").inject(:product)
      when config["longitudes"] && config["latitudes"]
        config.values_at("longitudes", "latitudes").inject(:product)
      when config["size"] && config["zone"] && config["easting"] && config["northing"]
        utm = Projection.utm(config["zone"])
        [ utm.reproject_to_wgs84(config.values_at("easting", "northing")) ]
      when config["size"] && config["longitude"] && config["latitude"]
        [ config.values_at("longitude", "latitude") ]
      when config["bounds"]
        bounds_path = Pathname.new(config["bounds"]).expand_path
        gps = GPS.new bounds_path
        polygon = gps.areas.first
        config["margin"] = 0 unless (gps.waypoints.any? || gps.tracks.any?)
        polygon ? polygon.first : gps.tracks.any? ? gps.tracks.to_a.transpose.first.inject(&:+) : gps.waypoints.to_a.transpose.first
      else
        abort "Error: map extent must be provided as a bounds file, zone/eastings/northings, zone/easting/northing/size, latitudes/longitudes or latitude/longitude/size"
      end
      
      @projection_centre = wgs84_points.transpose.map { |coords| 0.5 * (coords.max + coords.min) }
      @projection = config["utm"] ?
        Projection.utm(GridSource.zone(@projection_centre, Projection.wgs84)) :
        Projection.transverse_mercator(@projection_centre.first, 1.0)
      
      @declination = config["declination"]["angle"] if config["declination"]
      config["rotation"] = -declination if config["rotation"] == "magnetic"
      
      if config["size"]
        sizes = config["size"].split(/[x,]/).map(&:to_f)
        abort "Error: invalid map size: #{config["size"]}" unless sizes.length == 2 && sizes.all? { |size| size > 0.0 }
        @extents = sizes.map { |size| size * 0.001 * scale }
        @rotation = config["rotation"]
        abort "Error: cannot specify map size and auto-rotation together" if @rotation == "auto"
        abort "Error: map rotation must be between +/-45 degrees" unless @rotation.abs <= 45
        @centre = Projection.wgs84.reproject_to(@projection, @projection_centre)
      else
        puts "Calculating map bounds..."
        bounding_points = Projection.wgs84.reproject_to(@projection, wgs84_points)
        if config["rotation"] == "auto"
          @centre, @extents, @rotation = BoundingBox.minimum_bounding_box(bounding_points)
          @rotation *= 180.0 / Math::PI
        else
          @rotation = config["rotation"]
          abort "Error: map rotation must be between -45 and +45 degrees" unless rotation.abs <= 45
          @centre, @extents = bounding_points.map do |point|
            point.rotate_by(-rotation * Math::PI / 180.0)
          end.transpose.map do |coords|
            [ coords.max, coords.min ]
          end.map do |max, min|
            [ 0.5 * (max + min), max - min ]
          end.transpose
          @centre.rotate_by!(rotation * Math::PI / 180.0)
        end
        @extents.map! { |extent| extent + 2 * config["margin"] * 0.001 * @scale } if config["bounds"]
      end

      enlarged_extents = [ @extents[0] * Math::cos(@rotation * Math::PI / 180.0) + @extents[1] * Math::sin(@rotation * Math::PI / 180.0).abs, @extents[0] * Math::sin(@rotation * Math::PI / 180.0).abs + @extents[1] * Math::cos(@rotation * Math::PI / 180.0) ]
      @bounds = [ @centre, enlarged_extents ].transpose.map { |coord, extent| [ coord - 0.5 * extent, coord + 0.5 * extent ] }
    rescue BadGpxKmlFile => e
      abort "Error: invalid bounds file #{e.message}"
    end
    
    attr_reader :name, :scale, :projection, :bounds, :centre, :extents, :rotation
    
    def transform_bounds_to(target_projection)
      @projection.transform_bounds_to target_projection, bounds
    end
    
    def wgs84_bounds
      transform_bounds_to Projection.wgs84
    end
    
    def resolution_at(ppi)
      @scale * 0.0254 / ppi
    end
    
    def dimensions_at(ppi)
      @extents.map { |extent| (ppi * extent / @scale / 0.0254).floor }
    end
    
    def overlaps?(bounds)
      axes = [ [ 1, 0 ], [ 0, 1 ] ].map { |axis| axis.rotate_by(@rotation * Math::PI / 180.0) }
      bounds.inject(&:product).map do |corner|
        axes.map { |axis| corner.minus(@centre).dot(axis) }
      end.transpose.zip(@extents).none? do |projections, extent|
        projections.max < -0.5 * extent || projections.min > 0.5 * extent
      end
    end
    
    def write_world_file(path, resolution)
      topleft = [ @centre, @extents.rotate_by(-@rotation * Math::PI / 180.0), [ :-, :+ ] ].transpose.map { |coord, extent, plus_minus| coord.send(plus_minus, 0.5 * extent) }
      WorldFile.write topleft, resolution, @rotation, path
    end
    
    def write_oziexplorer_map(path, name, image, ppi)
      dimensions = dimensions_at(ppi)
      corners = @extents.map do |extent|
        [ -0.5 * extent, 0.5 * extent ]
      end.inject(:product).map do |offsets|
        [ @centre, offsets.rotate_by(rotation * Math::PI / 180.0) ].transpose.map { |coord, offset| coord + offset }
      end
      wgs84_corners = @projection.reproject_to_wgs84(corners).values_at(1,3,2,0)
      pixel_corners = [ dimensions, [ :to_a, :reverse ] ].transpose.map { |dimension, order| [ 0, dimension ].send(order) }.inject(:product).values_at(1,3,2,0)
      calibration_strings = [ pixel_corners, wgs84_corners ].transpose.map.with_index do |(pixel_corner, wgs84_corner), index|
        dmh = [ wgs84_corner, [ [ ?E, ?W ], [ ?N, ?S ] ] ].transpose.reverse.map do |coord, hemispheres|
          [ coord.abs.floor, 60 * (coord.abs - coord.abs.floor), coord > 0 ? hemispheres.first : hemispheres.last ]
        end
        "Point%02i,xy,%i,%i,in,deg,%i,%f,%c,%i,%f,%c,grid,,,," % [ index+1, pixel_corner, dmh ].flatten
      end
      path.open("w") do |file|
        file << %Q[OziExplorer Map Data File Version 2.2
#{name}
#{image}
1 ,Map Code,
WGS 84,WGS84,0.0000,0.0000,WGS84
Reserved 1
Reserved 2
Magnetic Variation,,,E
Map Projection,Transverse Mercator,PolyCal,No,AutoCalOnly,Yes,BSBUseWPX,No
#{calibration_strings.join ?\n}
Projection Setup,0.000000000,#{projection.central_meridian},#{projection.scale_factor},500000.00,10000000.00,,,,,
Map Feature = MF ; Map Comment = MC     These follow if they exist
Track File = TF      These follow if they exist
Moving Map Parameters = MM?    These follow if they exist
MM0,Yes
MMPNUM,4
#{pixel_corners.map.with_index { |pixel_corner, index| "MMPXY,#{index+1},#{pixel_corner.join ?,}" }.join ?\n}
#{wgs84_corners.map.with_index { |wgs84_corner, index| "MMPLL,#{index+1},#{wgs84_corner.join ?,}" }.join ?\n}
MM1B,#{resolution_at ppi}
MOP,Map Open Position,0,0
IWH,Map Image Width/Height,#{dimensions.join ?,}
].gsub(/\r\n|\r|\n/, "\r\n")
      end
    end
    
    def declination
      @declination ||= begin
        degrees_minutes_seconds = @projection_centre.map do |coord|
          [ (coord > 0 ? 1 : -1) * coord.abs.floor, (coord.abs * 60).floor % 60, (coord.abs * 3600).round % 60 ]
        end
        today = Date.today
        year_month_day = [ today.year, today.month, today.day ]
        url = "http://www.ga.gov.au/bin/geoAGRF?latd=%i&latm=%i&lats=%i&lond=%i&lonm=%i&lons=%i&elev=0&year=%i&month=%i&day=%i&Ein=D" % (degrees_minutes_seconds.reverse.flatten + year_month_day)
        HTTP.get(URI.parse url) do |response|
          /D\s*=\s*(\d+\.\d+)/.match(response.body) { |match| match.captures[0].to_f }
        end
      end
    end
    
    def xml
      millimetres = @extents.map { |extent| 1000.0 * extent / @scale }
      REXML::Document.new.tap do |xml|
        xml << REXML::XMLDecl.new(1.0, "utf-8")
        xml << REXML::DocType.new("svg", %Q[PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"])
        attributes = {
          "version" => 1.1,
          "baseProfile" => "full",
          "xmlns" => "http://www.w3.org/2000/svg",
          "xmlns:xlink" => "http://www.w3.org/1999/xlink",
          "xmlns:ev" => "http://www.w3.org/2001/xml-events",
          "xmlns:inkscape" => "http://www.inkscape.org/namespaces/inkscape",
          "xml:space" => "preserve",
          "width"  => "#{millimetres[0]}mm",
          "height" => "#{millimetres[1]}mm",
          "viewBox" => "0 0 #{millimetres[0]} #{millimetres[1]}",
          "enable-background" => "new 0 0 #{millimetres[0]} #{millimetres[1]}",
        }
        xml.add_element("svg", attributes) do |svg|
          svg.add_element("rect", "x" => 0, "y" => 0, "width" => millimetres[0], "height" => millimetres[1], "fill" => "white")
        end
      end
    end
    
    def svg_transform(millimetres_per_unit)
      if @rotation.zero?
        "scale(#{millimetres_per_unit})"
      else
        w, h = @bounds.map { |bound| 1000.0 * (bound.max - bound.min) / @scale }
        t = Math::tan(@rotation * Math::PI / 180.0)
        d = (t * t - 1) * Math::sqrt(t * t + 1)
        if t >= 0
          y = (t * (h * t - w) / d).abs
          x = (t * y).abs
        else
          x = -(t * (h + w * t) / d).abs
          y = -(t * x).abs
        end
        "translate(#{x} #{-y}) rotate(#{@rotation}) scale(#{millimetres_per_unit})"
      end
    end
  end
  
  InternetError = Class.new(Exception)
  ServerError = Class.new(Exception)
  BadGpxKmlFile = Class.new(Exception)
  BadLayerError = Class.new(Exception)
  NoVectorPDF = Class.new(Exception)
  
  module RetryOn
    def retry_on(*exceptions)
      intervals = [ 1, 2, 2, 4, 4, 8, 8 ]
      begin
        yield
      rescue *exceptions => e
        case
        when intervals.any?
          sleep(intervals.shift) and retry
        when File.identical?(__FILE__, $0)
          raise InternetError.new(e.message)
        else
          $stderr.puts "Error: #{e.message}"
          sleep(60) and retry
        end
      end
    end
  end
  
  module HTTP
    extend RetryOn
    def self.request(uri, req)
      retry_on(Timeout::Error, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EINVAL, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError) do
        response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
        case response
        when Net::HTTPSuccess then yield response
        else response.error!
        end
      end
    end

    def self.get(uri, *args, &block)
      request uri, Net::HTTP::Get.new(uri.request_uri, *args), &block
    end

    def self.post(uri, body, *args, &block)
      req = Net::HTTP::Post.new(uri.request_uri, *args)
      req.body = body.to_s
      request uri, req, &block
    end
    
    def self.head(uri, *args, &block)
      request uri, Net::HTTP::Head.new(uri.request_uri, *args), &block
    end
  end
  
  # class Colour
  #   def initialize(hex)
  #     r, g, b = rgb = hex.scan(/\h\h/).map(&:hex)
  #     mx = rgb.max
  #     mn = rgb.min
  #     c  = mx - mn
  #     @hue = c.zero? ? nil : mx == r ? 60 * (g - b) / c : mx == g ? 60 * (b - r) / c + 120 : 60 * (r - g) / c + 240
  #     @lightness = 100 * (mx + mn) / 510
  #     @saturation = c.zero? ? 0 : 10000 * c / (100 - (2 * @lightness - 100).abs) / 255
  #   end
  #   
  #   attr_accessor :hue, :lightness, :saturation
  #   
  #   def to_s
  #     c = (100 - (2 * @lightness - 100).abs) * @saturation * 255 / 10000
  #     x = @hue && c * (60 - (@hue % 120 - 60).abs) / 60
  #     m = 255 * @lightness / 100 - c / 2
  #     rgb = case @hue
  #     when   0..59  then [ m + c, m + x, m ]
  #     when  60..119 then [ m + x, m + c, m ]
  #     when 120..179 then [ m, m + c, m + x ]
  #     when 180..239 then [ m, m + x, m + c ]
  #     when 240..319 then [ m + x, m, m + c ]
  #     when 320..360 then [ m + c, m, m + x ]
  #     when nil      then [ 0, 0, 0 ]
  #     end
  #     "#%02x%02x%02x" % rgb
  #   end
  # end
  
  class Source
    def initialize(params = {})
      @params = params
    end
  
    attr_reader :params
    
    def path(label, options)
      ext = options["ext"] || params["ext"] || "png"
      Pathname.pwd + "#{label}.#{ext}"
    end
    
    def download(label, options, map)
      ext = options["ext"] || params["ext"] || "png"
      Dir.mktmppath do |temp_dir|
        FileUtils.cp get_source(label, ext, options, map, temp_dir), path(label, options)
      end
    end
  end
  
  module RasterRenderer
    def resolution_for(label, options, map)
      options["resolution"] || params["resolution"] || map.scale / 12500.0
    end
    
    def get_source(label, ext, options, map, temp_dir)
      resolution = resolution_for label, options, map
      dimensions = map.extents.map { |extent| (extent / resolution).ceil }
      pixels = dimensions.inject(:*) > 500000 ? " (%.1fMpx)" % (0.000001 * dimensions.inject(:*)) : nil
      puts "Creating: %s, %ix%i%s @ %.1f m/px" % [ label, *dimensions, pixels, resolution]
      get_raster(label, ext, options, map, dimensions, resolution, temp_dir)
    end
    
    def clip_paths(layer, label, options)
      [ *options["clips"] ].map do |sublayer|
        layer.parent.elements.collect("//g[contains(@id,'#{sublayer}')]//path[@fill-rule='evenodd']") { |path| path }
      end.inject([], &:+).map do |path|
        transform = path.elements.collect("ancestor-or-self::*[@transform]") do |element|
          element.attributes["transform"]
        end.reverse.join ?\s
        # # TODO: Ugly, ugly hack to invert each path by surrounding it with a path at +/- infinity...
        box = "M-1000000 -1000000 L1000000 -1000000 L1000000 100000 L-1000000 1000000 Z"
        d = "#{box} #{path.attributes['d']}"
        { "d" => d, "transform" => transform, "clip-rule" => "evenodd" }
      end.map.with_index do |attributes, index|
        REXML::Element.new("clipPath").tap do |clippath|
          clippath.add_attribute("id", [ label, "clip", index ].join(SEGMENT))
          clippath.add_element("path", attributes)
        end
      end
    end
    
    def render_svg(xml, label, options, map, &block)
      puts "  Rendering #{label}"
      resolution = resolution_for label, options, map
      transform = "scale(#{1000.0 * resolution / map.scale})"
      opacity = options["opacity"] || params["opacity"] || 1
      dimensions = map.extents.map { |extent| (extent / resolution).ceil }
      
      href = if respond_to?(:embed_image) && params["embed"] != false
        base64 = Dir.mktmppath do |temp_dir|
          Base64.encode64 embed_image(label, options, temp_dir).read
        end
        "data:image/png;base64,#{base64}"
      else
        path(label, options).tap do |raster_path|
          raise BadLayerError.new("#{label} raster image not found at #{raster_path}") unless raster_path.exist?
        end.basename
      end
      
      layer = REXML::Element.new("g")
      xml.elements["/svg/g[@id='#{label}']"].tap do |old_layer|
        old_layer ? old_layer.replace_with(layer) : yield(layer)
      end
      layer.add_attributes "id" => label, "style" => "opacity:#{opacity}"
      layer.add_element("defs", "id" => [ label, "tiles" ].join(SEGMENT)) do |defs|
        clip_paths(layer, label, options).each do |clippath|
          defs.elements << clippath
        end
      end.elements.collect("./clipPath") do |clippath|
        clippath.attributes["id"]
      end.inject(layer) do |group, clip_id|
        group.add_element("g", "clip-path" => "url(##{clip_id})")
      end.add_element("image",
        "transform" => transform,
        "width" => dimensions[0],
        "height" => dimensions[1],
        "image-rendering" => "optimizeQuality",
        "xlink:href" => href,
      )
      layer.elements.each("./defs[not(*)]", &:remove)
    end
  end
  
  class TiledServer < Source
    include RasterRenderer
    
    def get_raster(label, ext, options, map, dimensions, resolution, temp_dir)
      tile_paths = tiles(options, map, resolution, temp_dir).map do |tile_bounds, tile_resolution, tile_path|
        topleft = [ tile_bounds.first.min, tile_bounds.last.max ]
        WorldFile.write topleft, tile_resolution, 0, Pathname.new("#{tile_path}w")
        %Q["#{tile_path}"]
      end
      
      tif_path = temp_dir + "#{label}.tif"
      tfw_path = temp_dir + "#{label}.tfw"
      vrt_path = temp_dir + "#{label}.vrt"
      
      density = 0.01 * map.scale / resolution
      %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:black -type TrueColor -depth 8 "#{tif_path}"]
      unless tile_paths.empty?
        %x[gdalbuildvrt "#{vrt_path}" #{tile_paths.join ?\s}]
        map.write_world_file tfw_path, resolution
        resample = params["resample"] || "cubic"
        projection = Projection.new(params["projection"])
        %x[gdalwarp -s_srs "#{projection}" -t_srs "#{map.projection}" -r #{resample} "#{vrt_path}" "#{tif_path}"]
      end
      
      temp_dir.join("#{label}.#{ext}").tap do |output_path|
        %x[convert -quiet "#{tif_path}" "#{output_path}"]
      end
    end
  end
  
  class TiledMapServer < TiledServer
    def tiles(options, map, raster_resolution, temp_dir)
      tile_sizes = params["tile_sizes"]
      tile_limit = params["tile_limit"]
      crops = params["crops"] || [ [ 0, 0 ], [ 0, 0 ] ]
      
      cropped_tile_sizes = [ tile_sizes, crops ].transpose.map { |tile_size, crop| tile_size - crop.inject(:+) }
      projection = Projection.new(params["projection"])
      bounds = map.transform_bounds_to(projection)
      extents = bounds.map { |bound| bound.max - bound.min }
      origins = bounds.transpose.first
      
      zoom, resolution, counts = (Math::log2(Math::PI * EARTH_RADIUS / raster_resolution) - 7).ceil.downto(1).map do |zoom|
        resolution = Math::PI * EARTH_RADIUS / 2 ** (zoom + 7)
        counts = [ extents, cropped_tile_sizes ].transpose.map { |extent, tile_size| (extent / resolution / tile_size).ceil }
        [ zoom, resolution, counts ]
      end.find do |zoom, resolution, counts|
        counts.inject(:*) < tile_limit
      end
      
      format = options["format"]
      name = options["name"]
      
      puts "(Downloading #{counts.inject(:*)} tiles)"
      counts.map { |count| (0...count).to_a }.inject(:product).with_progress.map do |indices|
        sleep params["interval"]
        tile_path = temp_dir + "tile.#{indices.join ?.}.png"
  
        cropped_centre = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
          origin + tile_size * (index + 0.5) * resolution
        end
        centre = [ cropped_centre, crops ].transpose.map { |coord, crop| coord - 0.5 * crop.inject(:-) * resolution }
        bounds = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
          [ origin + index * tile_size * resolution, origin + (index + 1) * tile_size * resolution ]
        end
  
        longitude, latitude = projection.reproject_to_wgs84(centre)
  
        attributes = [ "longitude", "latitude", "zoom", "format", "hsize", "vsize", "name" ]
        values     = [  longitude,   latitude,   zoom,   format,      *tile_sizes,   name  ]
        uri_string = [ attributes, values ].transpose.inject(params["uri"]) do |string, array|
          attribute, value = array
          string.gsub(Regexp.new("\\$\\{#{attribute}\\}"), value.to_s)
        end
        uri = URI.parse(uri_string)
  
        retries_on_blank = params["retries_on_blank"] || 0
        (1 + retries_on_blank).times do
          HTTP.get(uri) do |response|
            tile_path.open("wb") { |file| file << response.body }
            %x[mogrify -quiet -crop #{cropped_tile_sizes.join ?x}+#{crops.first.first}+#{crops.last.last} -type TrueColor -depth 8 -format png -define png:color-type=2 "#{tile_path}"]
          end
          non_blank_fraction = %x[convert "#{tile_path}" -fill white +opaque black -format "%[fx:mean]" info:].to_f
          break if non_blank_fraction > 0.995
        end
        
        [ bounds, resolution, tile_path ]
      end
    end
  end
  
  class LPIOrthoServer < TiledServer
    def tiles(options, map, raster_resolution, temp_dir)
      projection = Projection.new(params["projection"])
      bounds = map.transform_bounds_to(projection)
      images_regions = case
      when options["image"]
        { options["image"] => options["region"] }
      when options["config"]
        HTTP.get(URI::HTTP.build(:host => params["host"], :path => options["config"])) do |response|
          vars, images = response.body.scan(/(.+)_ECWP_URL\s*?=\s*?.*"(.+)";/x).transpose
          regions = vars.map do |var|
            response.body.match(/#{var}_CLIP_REGION\s*?=\s*?\[(.+)\]/x) do |match|
              match[1].scan(/\[(.+?),(.+?)\]/x).map { |coords| coords.map(&:to_f) }
            end
          end
          [ images, regions ].transpose.map { |image, region| { image => region } }.inject({}, &:merge)
        end
      end
    
      otdf = options["otdf"]
      dll_path = otdf ? "/otdf/otdf.dll" : "/ImageX/ImageX.dll"
      uri = URI::HTTP.build(:host => params["host"], :path => dll_path, :query => "dsinfo?verbose=#{!otdf}&layers=#{images_regions.keys.join ?,}")
      images_attributes = HTTP.get(uri) do |response|
        xml = REXML::Document.new(response.body)
        raise ServerError.new(xml.elements["//Error"].text) if xml.elements["//Error"]
        coordspace = xml.elements["/DSINFO/COORDSPACE"]
        meterfactor = (coordspace.attributes["meterfactor"] || 1).to_f
        xml.elements.collect(otdf ? "/DSINFO" : "/DSINFO/LAYERS/LAYER") do |layer|
          image = layer.attributes[otdf ? "datafile" : "name"]
          sizes = [ "width", "height" ].map { |key| layer.attributes[key].to_i }
          bbox = layer.elements["BBOX"]
          resolutions = [ "cellsizeX", "cellsizeY" ].map { |key| bbox.attributes[key].to_f * meterfactor }
          tl = [ "tlX", "tlY" ].map { |key| bbox.attributes[key].to_f }
          br = [ tl, resolutions, sizes ].transpose.map { |coord, resolution, size| coord + size * resolution }
          layer_bounds = [ tl, br ].transpose.map(&:sort)
          { image => { "sizes" => sizes, "bounds" => layer_bounds, "resolutions" => resolutions, "regions" => images_regions[image] } }
        end.inject({}, &:merge)
      end.select do |image, attributes|
        [ bounds, attributes["bounds"] ].transpose.map do |bound1, bound2|
          bound1.max > bound2.min && bound1.min < bound2.max
        end.inject(:&)
      end
    
      if images_attributes.empty?
        []
      else
        tile_size = otdf ? 256 : params["tile_size"]
        format = images_attributes.one? ? { "type" => "jpg", "quality" => 90 } : { "type" => "png", "transparent" => true }
        images_attributes.map do |image, attributes|
          zoom = [ Math::log2(raster_resolution / attributes["resolutions"].first).floor, 0 ].max
          resolutions = attributes["resolutions"].map { |resolution| resolution * 2**zoom }
          [ bounds, attributes["bounds"], attributes["sizes"], resolutions ].transpose.map do |bound, layer_bound, size, resolution|
            layer_extent = layer_bound.reverse.inject(:-)
            first, order, plus = resolution > 0 ? [ :first, :to_a, :+ ] : [ :last, :reverse, :- ]
            tile_indices = bound.map do |coord|
              index = [ coord, layer_bound.send(first) ].send(order).inject(:-) * size / layer_extent
              [ [ index, 0 ].max, size - 1 ].min
            end.map do |pixel|
              (pixel / tile_size / 2**zoom).floor
            end.send(order).inject(:upto).to_a
            tile_bounds = tile_indices.map do |tile_index|
              [ tile_index, tile_index + 1 ].map do |index|
                layer_bound.send(first).send(plus, layer_extent * index * tile_size * (2**zoom) / size)
              end.send(order)
            end
            [ tile_indices, tile_bounds ].transpose
          end.inject(:product).map(&:transpose).map do |(tx, ty), tile_bounds|
            query = format.merge("l" => zoom, "tx" => tx, "ty" => ty, "ts" => tile_size, "layers" => image, "fillcolor" => "0x000000")
            query["inregion"] = "#{attributes["region"].flatten.join ?,},INSRC" if attributes["region"]
            [ "image?#{query.to_query}", tile_bounds, resolutions ]
          end
        end.inject(:+).with_progress.with_index.map do |(query, tile_bounds, resolutions), index|
          uri = URI::HTTP.build :host => params["host"], :path => dll_path, :query => URI.escape(query)
          tile_path = temp_dir + "tile.#{index}.#{format["type"]}"
          HTTP.get(uri) do |response|
            raise InternetError.new("no data received") if response.content_length.zero?
            begin
              xml = REXML::Document.new(response.body)
              raise ServerError.new(xml.elements["//Error"] ? xml.elements["//Error"].text.gsub("\n", " ") : "unexpected response")
            rescue REXML::ParseException
            end
            tile_path.open("wb") { |file| file << response.body }
          end
          sleep params["interval"]
          [ tile_bounds, resolutions.first, tile_path]
        end
      end
    end
  end
  
  class ArcGIS < Source
    UNDERSCORES = /[\s\(\)]/
    
    def initialize(params)
      super({ "tile_sizes" => [ 2048, 2048 ], "interval" => 0.1 }.merge params)
    end
    
    def tiles(map, resolution, margin = 0)
      cropped_tile_sizes = params["tile_sizes"].map { |tile_size| tile_size - margin }
      dimensions = map.bounds.map { |bound| ((bound.max - bound.min) / resolution).ceil }
      origins = [ map.bounds.first.min, map.bounds.last.max ]
      
      cropped_size_lists = [ dimensions, cropped_tile_sizes ].transpose.map do |dimension, cropped_tile_size|
        [ cropped_tile_size ] * ((dimension - 1) / cropped_tile_size) << 1 + (dimension - 1) % cropped_tile_size
      end
      
      bound_lists = [ cropped_size_lists, origins, [ :+, :- ] ].transpose.map do |cropped_sizes, origin, increment|
        boundaries = cropped_sizes.inject([ 0 ]) { |memo, size| memo << size + memo.last }
        [ 0..-2, 1..-1 ].map.with_index do |range, index|
          boundaries[range].map { |offset| origin.send increment, (offset + index * margin) * resolution }
        end.transpose.map(&:sort)
      end
      
      size_lists = cropped_size_lists.map do |cropped_sizes|
        cropped_sizes.map { |size| size + margin }
      end
      
      offset_lists = cropped_size_lists.map do |cropped_sizes|
        cropped_sizes[0..-2].inject([0]) { |memo, size| memo << memo.last + size }
      end
      
      [ bound_lists, size_lists, offset_lists ].map do |axes|
        axes.inject(:product)
      end.transpose.select do |bounds, sizes, offsets|
        map.overlaps? bounds
      end
    end
    
    def export_uri(options, query)
      service_type, function = options["image"] ? %w[ImageServer exportImage] : %w[MapServer export]
      path = [ "", params["instance"] || "arcgis", "rest", "services", options["folder"] || params["folder"], options["service"], service_type, function ].compact.join ?/
      URI::HTTP.build :host => params["host"], :path => path, :query => URI.escape(query.to_query)
    end
    
    def service_uri(options, query)
      service_type = options["image"] ? "ImageServer" : "MapServer"
      path = [ "", params["instance"] || "arcgis", "rest", "services", options["folder"] || params["folder"], options["service"], service_type ].compact.join ?/
      URI::HTTP.build :host => params["host"], :path => path, :query => URI.escape(query.to_query)
    end
    
    def get_tile(bounds, sizes, options)
      srs = { "wkt" => options["wkt"] }.to_json
      query = {
        "bbox" => bounds.transpose.flatten.join(?,),
        "bboxSR" => srs,
        "imageSR" => srs,
        "size" => sizes.join(?,),
        "f" => "image"
      }
      if options["image"]
        query.merge!(
          "format" => "png24",
          "interpolation" => options["interpolation"] || "RSP_BilinearInterpolation"
        )
      else
        query.merge!(
          "layers" => options["layers"],
          "layerDefs" => options["layerDefs"],
          "dpi" => options["dpi"],
          "format" => options["format"],
          "transparent" => true
        )
      end
      
      HTTP.get(export_uri(options, query), params["headers"]) do |response|
        block_given? ? yield(response.body) : response.body
      end
    end
    
    def rerender(map, element, commands)
      scale_by = lambda do |factor, string|
        string.split(/[,\s]+/).map { |number| factor * number.to_f }.join(?\s)
      end
      commands.inject({}) do |memo, (command, args)|
        memo.deep_merge case command
        when "colour" then { "stroke" => args, "fill" => args }
        when "expand" then { "widen" => args, "stretch" => args }
        else { command => args }
        end
      end.inject({}) do |memo, (command, args)|
        memo.deep_merge case command
        when %r{\.//}  then { command => args }
        when "opacity" then { "self::/@style" => "opacity:#{args}" }
        when "stroke", "fill"
          case args
          when Hash
            args.map { |colour, replacement|
              { ".//[@#{command}='#{colour}']/@#{command}" => replacement }
            }.inject(&:merge)
          else
            { ".//[@#{command}!='none']/@#{command}" => args }
          end
        when "widen", "stretch", "expand-glyph"
          case command
          when "widen"        then %w[stroke-width stroke-miterlimit]
          when "stretch"      then %w[stroke-dasharray]
          when "expand-glyph" then %w[font-size]
          end.map { |name| { ".//[@#{name}]/@#{name}" => scale_by.curry[args] } }.inject(&:merge)
        when "dash"
          case args
          when nil
            { ".//[@stroke-dasharray]/@stroke-dasharray" => nil }
          when String, Numeric
            { ".//path" => { "stroke-dasharray" => scale_by.(map.scale / 25000.0, args.to_s) } }
          end
        else { }
        end
      end.each do |xpath, args|
        REXML::XPath.each(element, xpath) do |node|
          case args
          when nil then node.remove
          when Hash
            case node
            when REXML::Element   then node.add_attributes(args)
            end
          when Proc
            case node
            when REXML::Attribute then node.element.attributes[node.name] = args.(node.value)
            end
          else
            case node
            when REXML::Attribute then node.element.attributes[node.name] = args
            when REXML::Text      then node.value = args
            end
          end
        end
      end
    end
    
    include RasterRenderer
    
    def get_source(label, ext, options, map, temp_dir)
      if params["cookie"] && !params["headers"]
        cookie = HTTP.head(URI.parse params["cookie"]) { |response| response["Set-Cookie"] }
        params["headers"] = { "Cookie" => cookie }
      end
      
      ext == "svg" ? get_vector(label, ext, options, map, temp_dir) : super(label, ext, options, map, temp_dir)
    end
    
    def render_svg(xml, label, options, map, &block)
      return super(xml, label, options, map, &block) unless options["ext"] == "svg"
      source_xml = path(label, options).tap do |vector_path|
        raise BadLayerError.new("source file not found at #{vector_path}") unless vector_path.exist?
      end.read
      source = REXML::Document.new(source_xml)
      
      if xml.elements.each("/svg/g[starts-with(@id,'#{label}#{SEGMENT}')]") do |layer|
        id = layer.attributes["id"]
        layer.replace_with source.elements["/svg/g[@id='#{id}']"]
      end.empty?
        source.elements.each("/svg/g[starts-with(@id,'#{label}#{SEGMENT}')][*]", &block)
        [ *options["exclude"] ].each do |sublabel|
          xml.elements.each("/svg/g[@id='#{[ label, sublabel ].join SEGMENT}']", &:remove)
        end
      end
      
      xml.elements.each("/svg/g[starts-with(@id,'#{label}#{SEGMENT}')][*]") do |layer|
        id = layer.attributes["id"]
        name = id.split(SEGMENT).last
        puts "  Rendering #{id}"
        render_sources = (options["equivalences"] || {}).select do |group, names|
          names.include? name
        end.map(&:first) << name
        render_sources.inject(options) do |memo, key|
          memo.deep_merge(options[key] || {})
        end.tap do |commands|
          rerender(map, layer, commands)
        end
        until layer.elements.each(".//g[not(*)]", &:remove).empty? do
        end
      end
      
      xml.elements.each("/svg/defs[starts-with(@id,'#{label}#{SEGMENT}')]", &:remove)
      source.elements.each("/svg/defs") { |defs| xml.elements["/svg"].unshift defs }
    end
    
    def get_raster(label, ext, options, map, dimensions, resolution, temp_dir)
      scale = options["scale"] || map.scale
      layer_options = { "dpi" => scale * 0.0254 / resolution, "wkt" => map.projection.wkt_esri, "format" => "png32" }
      
      dataset = tiles(map, resolution).with_progress.with_index.map do |(tile_bounds, tile_sizes, tile_offsets), tile_index|
        sleep params["interval"] if params["interval"]
        tile_path = temp_dir + "tile.#{tile_index}.png"
        tile_path.open("wb") do |file|
          file << get_tile(tile_bounds, tile_sizes, options.merge(layer_options))
        end
        [ tile_bounds, tile_sizes, tile_offsets, tile_path ]
      end
      
      temp_dir.join("#{label}.#{ext}").tap do |mosaic_path|
        density = 0.01 * map.scale / resolution
        alpha = options["background"] ? %Q[-background "#{options['background']}" -alpha Remove] : nil
        if map.rotation.zero?
          sequence = dataset.map do |_, tile_sizes, tile_offsets, tile_path|
            %Q[#{OP} "#{tile_path}" +repage -repage +#{tile_offsets[0]}+#{tile_offsets[1]} #{CP}]
          end.join ?\s
          resize = (options["resolution"] || options["scale"]) ? "-resize #{dimensions.join ?x}!" : "" # TODO: check?
          %x[convert #{sequence} -compose Copy -layers mosaic -units PixelsPerCentimeter -density #{density} #{resize} #{alpha} "#{mosaic_path}"]
        else
          tile_paths = dataset.map do |tile_bounds, _, _, tile_path|
            topleft = [ tile_bounds.first.first, tile_bounds.last.last ]
            WorldFile.write topleft, resolution, 0, Pathname.new("#{tile_path}w")
            %Q["#{tile_path}"]
          end.join ?\s
          vrt_path = temp_dir + "#{label}.vrt"
          tif_path = temp_dir + "#{label}.tif"
          tfw_path = temp_dir + "#{label}.tfw"
          %x[gdalbuildvrt "#{vrt_path}" #{tile_paths}]
          %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type TrueColorMatte -depth 8 "#{tif_path}"]
          map.write_world_file tfw_path, resolution
          %x[gdalwarp -s_srs "#{map.projection}" -t_srs "#{map.projection}" -dstalpha -r cubic "#{vrt_path}" "#{tif_path}"]
          %x[convert "#{tif_path}" -quiet #{alpha} "#{mosaic_path}"]
        end
      end
    end
    
    def get_vector(label, ext, options, map, temp_dir)
      puts "Downloading: #{label}"
      service = HTTP.get(service_uri(options, "f" => "json"), params["headers"]) do |response|
        JSON.parse(response.body).tap do |result|
          raise Net::HTTPBadResponse.new(result["error"]["message"]) if result["error"]
        end
      end
      service["layers"].each { |layer| layer["name"] = layer["name"].gsub UNDERSCORES, ?_ }
      service_map_name = options["service-map-name"] || service["mapName"].gsub(UNDERSCORES, ?_)
      layer_ids = service["layers"].map { |layer| layer["name"].sub(/^\d/, ?_) }
      
      resolution = resolution_for label, options, map
      transform = map.svg_transform(1000.0 * resolution / map.scale)
      tile_list = tiles(map, resolution, 3) # TODO: margin of 3 means what?
      
      downloads = %w[features text].select do |type|
        options[type]
      end.map do |type|
        case options[type]
        when Hash
          options[type].map do |scale_or_multiplier, layers|
            case scale_or_multiplier
            when Integer then [ scale_or_multiplier, layers]
            when Float then [ scale_or_multiplier * map.scale, layers ]
            when nil then [ map.scale, layers ]
            end
          end
        when String, Array
          { map.scale => [ *options[type] ] }
        when true
          { map.scale => service["layers"].select { |layer| layer["parentLayerId"] == -1 }.map { |layer| layer["name"] } }
        end.map do |scale, layers|
          dpi = scale * 0.0254 / resolution
          if params["integer-dpi"]
            dpi = dpi.floor
            scale = dpi * resolution / 0.0254
          end
          layers.map do |key, value|
            case value
            when String then { key => { "name" => value } }  # key is a sublabel, value is a layer name
            when Fixnum then { key => { "id" => value } }    # key is a sublabel, value is a layer ID
            when Hash   then { key => value }                # key is a sublabel, value is layer options
            when nil
              case key
              when String then { key => { "name" => key } }  # key is a layer name
              when Hash                                      # key is a layer name with definition
                { key.first.first => { "name" => key.first.first, "definition" => key.first.last } }
              when Fixnum                                    # key is a layer ID
                layer = service["layers"].find { |layer| layer["id"] == key }
                { layer["name"] => { "id" => layer["id"] } }
              end
            end
          end.inject(&:merge).each do |sublabel, layer_options|
            layer_options["name"] = layer_options["name"].gsub UNDERSCORES, ?_
            layer_options["id"]   ||= service["layers"].find { |layer| layer["name"] == layer_options["name"] }.fetch("id")
            layer_options["name"] ||= service["layers"].find { |layer| layer["id"]   == layer_options["id"]   }.fetch("name")
            layer_options["name"] = layer_options["name"].gsub UNDERSCORES, ?_
          end.inject([]) do |memo, (sublabel, layer_options)|
            memo.find do |group|
              group.none? do |_, other_layer_options|
                other_layer_options["id"] == layer_options["id"]
              end
            end.tap do |group|
              group ||= (memo << []).last
              group << [ sublabel, layer_options ]
            end
            memo
          end.map do |group|
            [ scale, dpi, Hash[group], type ]
          end
        end
      end.inject(:+).inject(:+)
      
      tilesets = tile_list.with_progress.map do |tile_bounds, tile_sizes, tile_offsets|
        tileset = downloads.map do |scale, dpi, group, type|
          sleep params["interval"] if params["interval"]
          ids, layer_defs = group.values.map do |layer_options|
            id, definition = layer_options.values_at("id", "definition")
            layer_def = "#{id}:#{definition}" if definition
            [ id, layer_def ]
          end.transpose
          group_options = { "dpi" => dpi, "wkt" => map.projection.wkt_esri, "format" => "svg" }
          group_options.merge!("layers" => "show:#{ids.join ?,}") if ids && ids.any?
          group_options.merge!("layerDefs" => layer_defs.compact.join(?;)) if layer_defs && layer_defs.compact.any?
          tile_xml = get_tile(tile_bounds, tile_sizes, options.merge(group_options)) do |tile_data|
            tile_data.gsub! /ESRITransportation\&?Civic/, %Q['ESRI Transportation &amp; Civic']
            tile_data.gsub!  /ESRIEnvironmental\&?Icons/, %Q['ESRI Environmental &amp; Icons']
            tile_data.gsub! /Arial\s?MT/, "Arial"
            tile_data.gsub! "ESRISDS1.951", %Q['ESRI SDS 1.95 1']
            [ /id="(\w+)"/, /url\(#(\w+)\)"/, /xlink:href="#(\w+)"/ ].each do |regex|
              tile_data.gsub! regex do |match|
                case $1
                when "Labels", service_map_name, *layer_ids then match
                else match.sub $1, [ label, type, scale, *tile_offsets, $1 ].compact.join(SEGMENT)
                end
              end
            end
            begin
              REXML::Document.new(tile_data)
            rescue REXML::ParseException => e
              raise ServerError.new("Bad XML data received: #{e.message}")
            end
          end
          xpath = case type
          when "features" then "/svg//g[@id='#{service_map_name}']//g[@id!='Labels']"
          when "text"     then "/svg//g[@id='#{service_map_name}']//g[@id='Labels']"
          end
          [ scale, type, tile_xml, xpath ]
        end
        [ tileset, tile_offsets ]
      end
      
      xml = map.xml
      xml.elements["/svg"].add_element("defs", "id" => [ label, "tiles" ].join(SEGMENT)) do |defs|
        tile_list.each do |tile_bounds, tile_sizes, tile_offsets|
          defs.add_element("clipPath", "id" => [ label, "tile", *tile_offsets ].join(SEGMENT)) do |clippath|
            clippath.add_element("rect", "width" => tile_sizes[0], "height" => tile_sizes[1])
          end
        end
      end
      
      layerset = downloads.map do |scale, dpi, group, type|
        case type
        when "features"
          group.map do |sublabel, layer_options|
            feature_layer = REXML::Element.new("g").tap do |layer|
              layer.add_attributes("id" => [ label, sublabel ].join(SEGMENT), "style" => "opacity:1", "transform" => transform)
            end
            [ layer_options["name"], layer_options["id"], feature_layer ]
          end
        when "text"
          label_layer = REXML::Element.new("g").tap do |layer|
            layer.add_attributes("id" => [ label, "labels" ].join(SEGMENT), "style" => "opacity:1", "transform" => transform)
          end
          [ [ "Labels", -1, label_layer ] ]
        end
      end
      
      layerset.inject(&:+).sort_by do |name, id, layer|
        -id
      end.each do |name, id, layer|
        xml.elements["/svg"].elements << layer
      end
      
      tilesets.with_progress("Assembling: #{label}").each do |tileset, tile_offsets|
        [ tileset, layerset ].transpose.each do |(scale, type, tile_xml, xpath), layers|
          tile_xml.elements.collect(xpath) do |layer_xml|
            _, _, layer = layers.find do |name, _, _|
              layer_xml.attributes["id"] == name.sub(/^\d/, ?_)
            end
            layer ? [ layer_xml, layer ] : nil
          end.compact.each do |layer_xml, layer|
            layer_xml.parent.attributes["opacity"].tap do |opacity|
              layer.add_attribute("style", "opacity:#{opacity}") if opacity
            end
            tile_transform = "translate(#{tile_offsets.join ?\s})"
            clip_path = "url(##{[ label, 'tile', *tile_offsets ].join(SEGMENT)})"
            layer.add_element("g", "transform" => tile_transform, "clip-path" => clip_path) do |tile|
              case type
              when "features"
                rerender(map, layer_xml, "expand" => map.scale.to_f / scale) if scale != map.scale
              when "text"
                layer_xml.elements.each(".//pattern | .//path | .//font", &:remove)
                layer_xml.deep_clone.tap do |copy|
                  copy.elements.each(".//text") { |text| text.add_attributes("stroke" => "white", "opacity" => 0.75) }
                end.elements.each { |element| tile << element }
              end
              layer_xml.elements.each { |element| tile << element }
            end
          end
        end
      end
      
      xml.elements.each("//path[@d='']", &:remove)
      until xml.elements.each("/svg/g[@id]//g[not(*)]", &:remove).empty? do
      end
      xml.elements["//defs"].remove unless xml.elements["/svg/g[*]"]
      
      temp_dir.join("#{label}.svg").tap do |mosaic_path|
        File.write mosaic_path, xml
      end
    rescue REXML::ParseException => e
      abort "Bad XML received:\n#{e.message}"
    end
  end
  
  module NoDownload
    def download(label, options, map)
      raise BadLayerError.new("#{label} file not found at #{path(label, options)}")
    end
  end
  
  class ReliefSource < Source
    include RasterRenderer
    
    def get_raster(label, ext, options, map, dimensions, resolution, temp_dir)
      dem_path = if options["path"]
        Pathname.new(options["path"]).expand_path
      else
        tile_sizes = params["tile_sizes"]
        degrees_per_pixel = 3.0 / 3600
        bounds = map.wgs84_bounds.map do |bound|
          [ (bound.first / degrees_per_pixel).floor * degrees_per_pixel, (bound.last / degrees_per_pixel).ceil * degrees_per_pixel ]
        end
        counts = [ bounds, tile_sizes ].transpose.map do |bound, tile_size|
          ((bound.max - bound.min) / degrees_per_pixel / tile_size).ceil
        end
        tile_paths = [ counts, bounds, tile_sizes ].transpose.map do |count, bound, tile_size|
          boundaries = (0..count).map { |index| bound.first + index * degrees_per_pixel * tile_size }
          [ boundaries[0..-2], boundaries[1..-1] ].transpose
        end.inject(:product).map.with_index do |tile_bounds, index|
          tile_path = temp_dir + "tile.#{index}.tif"
          bbox = tile_bounds.transpose.map { |corner| corner.join ?, }.join ?,
          query = {
            "service" => "WMS",
            "version" => "1.1.0",
            "request" => "GetMap",
            "styles" => "",
            "srs" => "EPSG:4326",
            "bbox" => bbox,
            "width" => tile_sizes[0],
            "height" => tile_sizes[1],
            "format" => "image/tiff",
            "layers" => "srtmv4.1_s0_pyramidal_16bits",
          }.to_query
          uri = URI::HTTP.build :host => "www.webservice-energy.org", :path => "/mapserv/srtm", :query => URI.escape(query)
          HTTP.get(uri) do |response|
            tile_path.open("wb") { |file| file << response.body }
            sleep params["interval"]
          end
          %Q["#{tile_path}"]
        end
    
        temp_dir.join("dem.vrt").tap do |vrt_path|
          %x[gdalbuildvrt "#{vrt_path}" #{tile_paths.join ?\s}]
        end
      end
      raise BadLayerError.new("elevation data not found at #{dem_path}") unless dem_path.exist?
      
      relief_path = temp_dir + "#{label}-small.tif"
      tif_path = temp_dir + "#{label}.tif"
      tfw_path = temp_dir + "#{label}.tfw"
      map.write_world_file tfw_path, resolution
      density = 0.01 * map.scale / resolution
      altitude = options["altitude"]
      azimuth = options["azimuth"]
      exaggeration = options["exaggeration"]
      %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type Grayscale -depth 8 "#{tif_path}"]
      %x[gdaldem hillshade -s 111120 -alt #{altitude} -z #{exaggeration} -az #{azimuth} "#{dem_path}" "#{relief_path}" -q]
      raise BadLayerError.new("invalid elevation data") unless $?.success?
      %x[gdalwarp -s_srs "#{Projection.wgs84}" -t_srs "#{map.projection}" -r bilinear "#{relief_path}" "#{tif_path}"]
      
      temp_dir.join("#{label}.#{ext}").tap do |output_path|
        %x[convert "#{tif_path}" -channel Red -separate -quiet -depth 8 -type Grayscale "#{output_path}"]
      end
    end
    
    def embed_image(label, options, temp_dir)
      hillshade_path = path(label, options)
      raise BadLayerError.new("hillshade image not found at #{hillshade_path}") unless hillshade_path.exist?
      highlights = options["highlights"]
      shade = %Q["#{hillshade_path}" -colorspace Gray -level 0,65% -negate -alpha Copy -fill black +opaque black]
      sun = %Q["#{hillshade_path}" -colorspace Gray -level 80%,100% +level 0,#{highlights}% -alpha Copy -fill yellow +opaque yellow]
      temp_dir.join("overlay.png").tap do |overlay_path|
        %x[convert #{OP} #{shade} #{CP} #{OP} #{sun} #{CP} -composite "#{overlay_path}"]
      end
    end
  end
  
  class VegetationSource < Source
    include RasterRenderer
    
    def get_raster(label, ext, options, map, dimensions, resolution, temp_dir)
      source_paths = [ *options["path"] ].tap do |paths|
        raise BadLayerError.new("no vegetation data file specified") if paths.empty?
      end.map do |source_path|
        Pathname.new(source_path).expand_path
      end.map do |source_path|
        raise BadLayerError.new("vegetation data file not found at #{source_path}") unless source_path.file?
        %Q["#{source_path}"]
      end.join ?\s
      
      vrt_path = temp_dir + "#{label}.vrt"
      tif_path = temp_dir + "#{label}.tif"
      tfw_path = temp_dir + "#{label}.tfw"
      clut_path = temp_dir + "#{label}-clut.png"
      mask_path = temp_dir + "#{label}-mask.png"
      
      %x[gdalbuildvrt "#{vrt_path}" #{source_paths}]
      map.write_world_file tfw_path, resolution
      %x[convert -size #{dimensions.join ?x} canvas:white -type Grayscale -depth 8 "#{tif_path}"]
      %x[gdalwarp -t_srs "#{map.projection}" "#{vrt_path}" "#{tif_path}"]
      
      low, high = { "low" => 0, "high" => 100 }.merge(options["contrast"] || {}).values_at("low", "high")
      fx = options["mapping"].inject(0.0) do |memo, (key, value)|
        "j==#{key} ? %.5f : (#{memo})" % (value < low ? 0.0 : value > high ? 1.0 : (value - low).to_f / (high - low))
      end
      
      %x[convert -size 1x256 canvas:black -fx "#{fx}" "#{clut_path}"]
      %x[convert "#{tif_path}" "#{clut_path}" -clut "#{mask_path}"]
      
      woody, nonwoody = options["colour"].values_at("woody", "non-woody")
      density = 0.01 * map.scale / resolution
      temp_dir.join("#{label}.png").tap do |png_path|
        %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:"#{nonwoody}" #{OP} "#{mask_path}" -background "#{woody}" -alpha Shape #{CP} -composite "#{png_path}"]
      end
    end
    
    def embed_image(label, options, temp_dir)
      path(label, options).tap do |vegetation_path|
        raise BadLayerError.new("vegetation raster image not found at #{vegetation_path}") unless vegetation_path.exist?
      end
    end
  end
  
  class CanvasSource < Source
    include RasterRenderer
    include NoDownload
    
    def resolution_for(label, options, map)
      return options["resolution"] if options["resolution"]
      canvas_path = path(label, options)
      raise BadLayerError.new("canvas image not found at #{canvas_path}") unless canvas_path.exist?
      pixels_per_centimeter = %x[convert "#{canvas_path}" -units PixelsPerCentimeter -format "%[resolution.x]" info:]
      raise BadLayerError.new("bad canvas image at #{canvas_path}") unless $?.success?
      map.scale * 0.01 / pixels_per_centimeter.to_f
    end
    
    def path(label, options)
      Pathname.pwd + "#{label}.png"
    end
  end
  
  class ImportSource < Source
    include RasterRenderer
    
    def resolution_for(label, options, map)
      import_path = Pathname.new(options["path"]).expand_path
      Math::sqrt(0.5) * [ [ 0, 0 ], [ 1, 1 ] ].map do |point|
        %x[echo #{point.join ?\s} | gdaltransform "#{import_path}" -t_srs "#{map.projection}"].tap do |output|
          raise BadLayerError.new("couldn't use georeferenced file at #{import_path}") unless $?.success?
        end.split(?\s)[0..1].map(&:to_f)
      end.inject(&:minus).norm
    end
    
    def get_raster(label, ext, options, map, dimensions, resolution, temp_dir)
      import_path = Pathname.new(options["path"]).expand_path
      source_path = temp_dir + "source.tif"
      tfw_path = temp_dir + "#{label}.tfw"
      tif_path = temp_dir + "#{label}.tif"
      
      density = 0.01 * map.scale / resolution
      map.write_world_file tfw_path, resolution
      %x[convert -size #{dimensions.join ?x} canvas:none -type TrueColorMatte -depth 8 -units PixelsPerCentimeter -density #{density} "#{tif_path}"]
      %x[gdal_translate -expand rgba #{import_path} #{source_path}]
      %x[gdal_translate #{import_path} #{source_path}] unless $?.success?
      raise BadLayerError.new("couldn't use georeferenced file at #{import_path}") unless $?.success?
      %x[gdalwarp -t_srs "#{map.projection}" -r bilinear #{source_path} #{tif_path}]
      temp_dir.join("#{label}.#{ext}").tap do |raster_path|
        %x[convert "#{tif_path}" -quiet "#{raster_path}"]
      end
    end
    
    def path(label, options)
      Pathname.pwd + "#{label}.png"
    end
  end
  
  class AnnotationSource < Source
    include NoDownload
    
    def render_svg(xml, label, options, map, &block)
      puts "  Rendering #{label}"
      opacity = options["opacity"] || params["opacity"] || 1
      layer = REXML::Element.new("g")
      xml.elements["/svg/g[@id='#{label}']"].tap do |old_layer|
        old_layer ? old_layer.replace_with(layer) : yield(layer)
      end
      layer.add_attributes "id" => label, "style" => "opacity:#{opacity}", "transform" => map.svg_transform(1)
      draw(layer, options, map) do |coords, projection|
        projection.reproject_to(map.projection, coords).one_or_many do |easting, northing|
          [ easting - map.bounds.first.first, map.bounds.last.last - northing ].map do |metres|
            1000.0 * metres / map.scale
          end
        end
      end
    end
  end
  
  class DeclinationSource < AnnotationSource
    def path(label, options)
      nil
    end
    
    def draw(group, options, map)
      centre = map.wgs84_bounds.map { |bound| 0.5 * bound.inject(:+) }
      projection = Projection.transverse_mercator(centre.first, 1.0)
      spacing = options["spacing"] / Math::cos(map.declination * Math::PI / 180.0)
      bounds = map.transform_bounds_to(projection)
      extents = bounds.map { |bound| bound.max - bound.min }
      longitudinal_extent = extents[0] + extents[1] * Math::tan(map.declination * Math::PI / 180.0)
      0.upto(longitudinal_extent / spacing).map do |count|
        map.declination > 0 ? bounds[0][1] - count * spacing : bounds[0][0] + count * spacing
      end.map do |easting|
        eastings = [ easting, easting + extents[1] * Math::tan(map.declination * Math::PI / 180.0) ]
        northings = bounds.last
        [ eastings, northings ].transpose
      end.map do |line|
        yield line, projection
      end.map do |line|
        "M%f %f L%f %f" % line.flatten
      end.each do |d|
        group.add_element("path", "d" => d, "stroke" => options["colour"], "stroke-width" => options["width"])
      end
    end
  end
  
  class GridSource < AnnotationSource
    def path(label, options)
      nil
    end
    
    def self.zone(coords, projection)
      projection.reproject_to_wgs84(coords).one_or_many do |longitude, latitude|
        (longitude / 6).floor + 31
      end
    end
    
    def draw(group, options, map)
      interval = options["interval"]
      label_spacing = options["label-spacing"]
      label_interval = label_spacing * interval
      fontfamily = options["family"]
      fontsize = 25.4 * options["fontsize"] / 72.0
      strokewidth = options["width"]
      
      GridSource.zone(map.bounds.inject(&:product), map.projection).inject do |range, zone|
        [ *range, zone ].min .. [ *range, zone ].max
      end.each do |zone|
        projection = Projection.utm(zone)
        eastings, northings = map.transform_bounds_to(projection).map do |bound|
          (bound[0] / interval).floor .. (bound[1] / interval).ceil
        end.map do |counts|
          counts.map { |count| count * interval }
        end
        grid = eastings.map do |easting|
          column = [ easting ].product(northings.reverse)
          in_zone = GridSource.zone(column, projection).map { |candidate| candidate == zone }
          [ in_zone, column ].transpose
        end
        [ grid, grid.transpose ].each.with_index do |gridlines, index|
          gridlines.each do |gridline|
            line = gridline.select(&:first).map(&:last)
            yield(line, projection).map do |point|
              point.join ?\s
            end.join(" L").tap do |d|
              group.add_element("path", "d" => "M#{d}", "stroke-width" => strokewidth, "stroke" => options["colour"])
            end
            if line[0] && line[0][index] % label_interval == 0 
              coord = line[0][index]
              label_segments = [ [ "%d", (coord / 100000), 80 ], [ "%02d", (coord / 1000) % 100, 100 ] ]
              label_segments << [ "%03d", coord % 1000, 80 ] unless label_interval % 1000 == 0
              label_segments.map! { |template, number, percent| [ template % number, percent ] }
              line.inject do |*segment|
                if segment[0][1-index] % label_interval == 0
                  points = segment.map { |coords| yield coords, projection }
                  middle = points.transpose.map { |values| 0.5 * values.inject(:+) }
                  angle = 180.0 * Math::atan2(*points[1].minus(points[0]).reverse) / Math::PI
                  transform = "translate(#{middle.join ?\s}) rotate(#{angle})"
                  [ [ "white", "white" ], [ options["colour"], "none" ] ].each do |fill, stroke|
                    group.add_element("text", "transform" => transform, "dy" => 0.25 * fontsize, "stroke-width" => 0.15 * fontsize, "font-family" => fontfamily, "font-size" => fontsize, "fill" => fill, "stroke" => stroke, "text-anchor" => "middle") do |text|
                      label_segments.each do |digits, percent|
                        text.add_element("tspan", "font-size" => "#{percent}%") do |tspan|
                          tspan.add_text(digits)
                        end
                      end
                    end
                  end
                end
                segment.last
              end
            end
          end
        end
      end
    end
  end
  
  class ControlSource < AnnotationSource
    def path(label, options)
      Pathname.new(options["path"]).expand_path
    end
    
    def draw(group, options, map)
      gps = GPS.new Pathname.new(options["path"]).expand_path
      radius = 0.5 * options["diameter"]
      strokewidth = options["thickness"]
      fontfamily = options["family"]
      fontsize = 25.4 * options["fontsize"] / 72.0
      
      [ [ /\d{2,3}/, :circle,   options["colour"] ],
        [ /HH/,      :triangle, options["colour"] ],
        [ /ANC/,     :square,   options["colour"] ],
        [ /W/,       :water,    options["water-colour"] ],
      ].each do |selector, type, colour|
        gps.waypoints.map do |waypoint, name|
          [ yield(waypoint, Projection.wgs84), name[selector] ]
        end.select do |point, label|
          label
        end.each do |point, label|
          transform = "translate(#{point.join ?\s}) rotate(#{-map.rotation})"
          group.add_element("g", "transform" => transform) do |rotated|
            case type
            when :circle
              rotated.add_element("circle", "r"=> radius, "fill" => "none", "stroke" => colour, "stroke-width" => strokewidth)
            when :triangle, :square
              angles = type == :triangle ? [ -90, -210, -330 ] : [ -45, -135, -225, -315 ]
              points = angles.map do |angle|
                [ radius, 0 ].rotate_by(angle * Math::PI / 180.0)
              end.map { |vertex| vertex.join ?, }.join ?\s
              rotated.add_element("polygon", "points" => points, "fill" => "none", "stroke" => colour, "stroke-width" => strokewidth)
            when :water
              rotated.add_element("g", "transform" => "scale(#{radius * 0.8})") do |scaled|
                [
                  "m -0.79942321,0.07985921 -0.005008,0.40814711 0.41816285,0.0425684 0,-0.47826034 -0.41315487,0.02754198 z",
                  "m -0.011951449,-0.53885114 0,0.14266384",
                  "m 0.140317871,-0.53885114 0,0.14266384",
                  "m -0.38626833,0.05057523 c 0.0255592,0.0016777 0.0370663,0.03000538 0.0613473,0.03881043 0.0234708,0.0066828 0.0475564,0.0043899 0.0713631,0.0025165 0.007966,-0.0041942 0.0530064,-0.03778425 0.055517,-0.04287323 0.0201495,-0.01674888 0.0473913,-0.05858754 0.0471458,-0.08232678 l 0.005008,-0.13145777 c 2.5649e-4,-0.006711 -0.0273066,-0.0279334 -0.0316924,-0.0330336 -0.005336,-0.006207 0.006996,-0.0660504 -0.003274,-0.0648984 -0.0115953,-0.004474 -0.0173766,5.5923e-4 -0.0345371,-0.007633 -0.004228,-0.0128063 -0.006344,-0.0668473 0.0101634,-0.0637967 0.0278325,0.001678 0.0452741,0.005061 0.0769157,-0.005732 0.0191776,0 0.08511053,-0.0609335 0.10414487,-0.0609335 l 0.16846578,8.3884e-4 c 0.0107679,0 0.0313968,0.0284032 0.036582,0.03359 0.0248412,0.0302766 0.0580055,0.0372558 0.10330712,0.0520893 0.011588,0.001398 0.0517858,-0.005676 0.0553021,0.002517 0.007968,0.0265354 0.005263,0.0533755 0.003112,0.0635227 -0.002884,0.0136172 -0.0298924,-1.9573e-4 -0.0313257,0.01742 -0.001163,0.0143162 -4.0824e-4,0.0399429 -0.004348,0.0576452 -0.0239272,0.024634 -0.0529159,0.0401526 -0.0429639,0.0501152 l -6.5709e-4,0.11251671 c 0.003074,0.02561265 0.0110277,0.05423115 0.0203355,0.07069203 0.026126,0.0576033 0.0800901,0.05895384 0.0862871,0.06055043 0.002843,8.3885e-4 0.24674425,0.0322815 0.38435932,0.16401046 0.0117097,0.0112125 0.0374559,0.0329274 0.0663551,0.12144199 0.0279253,0.0855312 0.046922,0.36424768 0.0375597,0.36808399 -0.0796748,0.0326533 -0.1879149,0.0666908 -0.31675221,0.0250534 -0.0160744,-0.005201 0.001703,-0.11017354 -0.008764,-0.16025522 -0.0107333,-0.0513567 3.4113e-4,-0.15113981 -0.11080061,-0.17089454 -0.0463118,-0.008221 -0.19606469,0.0178953 -0.30110236,0.0400631 -0.05001528,0.0105694 -0.117695,0.0171403 -0.15336817,0.0100102 -0.02204477,-0.004418 -0.15733412,-0.0337774 -0.18225582,-0.0400072 -0.0165302,-0.004138 -0.053376,-0.006263 -0.10905742,0.0111007 -0.0413296,0.0128902 -0.0635168,0.0443831 -0.0622649,0.0334027 9.1434e-4,-0.008025 0.001563,-0.46374837 -1.0743e-4,-0.47210603 z",
                  "m 0.06341799,-0.8057541 c -0.02536687,-2.7961e-4 -0.06606003,0.0363946 -0.11502538,0.0716008 -0.06460411,0.0400268 -0.1414687,0.0117718 -0.20710221,-0.009675 -0.0622892,-0.0247179 -0.16166212,-0.004194 -0.17010213,0.0737175 0.001686,0.0453982 0.0182594,0.1160762 0.0734356,0.11898139 0.0927171,-0.0125547 0.18821206,-0.05389 0.28159685,-0.0236553 0.03728388,0.0164693 0.0439921,0.0419813 0.04709758,0.0413773 l 0.18295326,0 c 0.003105,5.5923e-4 0.009814,-0.0249136 0.0470976,-0.0413773 0.0933848,-0.0302347 0.18887978,0.0111007 0.2815969,0.0236553 0.0551762,-0.002908 0.0718213,-0.0735832 0.0735061,-0.11898139 -0.00844,-0.0779145 -0.10788342,-0.0984409 -0.17017266,-0.0737175 -0.0656335,0.0214464 -0.14249809,0.0497014 -0.20710215,0.009675 -0.0498479,-0.0358409 -0.09110973,-0.0731946 -0.11636702,-0.0715309 -4.5577e-4,-3.076e-5 -9.451e-4,-6.432e-5 -0.001412,-6.991e-5 z",
                  "m -0.20848487,-0.33159571 c 0.29568578,0.0460357 0.5475498,0.0168328 0.5475498,0.0168328",
                  "m -0.21556716,-0.26911875 c 0.29568578,0.0460329 0.55463209,0.0221175 0.55463209,0.0221175",
                ].each do |d|
                  scaled.add_element("path", "fill" => "none", "stroke" => colour, "stroke-width" => strokewidth / radius, "d" => d)
                end
              end
            end
            rotated.add_element("text", "dx" => radius, "dy" => -radius, "font-family" => fontfamily, "font-size" => fontsize, "fill" => colour, "stroke" => "none") do |text|
              text.add_text label
            end unless type == :water
          end
        end
      end
    rescue BadGpxKmlFile => e
      raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
    end
  end
  
  class OverlaySource < AnnotationSource
    def path(label, options)
      Pathname.new(options["path"]).expand_path
    end
    
    def draw(group, options, map)
      width, colour = options.values_at "width", "colour"
      gps = GPS.new Pathname.new(options["path"]).expand_path
      [ [ :tracks, "polyline", { "fill" => "none", "stroke" => colour, "stroke-width" => width } ],
        [ :areas, "polygon", { "fill" => colour, "stroke" => "none" } ]
      ].each do |feature, element, attributes|
        gps.send(feature).each do |list, name|
          points = yield(list, Projection.wgs84).map { |point| point.join ?, }.join ?\s
          group.add_element(element, attributes.merge("points" => points))
        end
      end
    rescue BadGpxKmlFile => e
      raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
    end
  end
  
  module KMZ
    TILE_SIZE = 512
    TILT = 40 * Math::PI / 180.0
    FOV = 30 * Math::PI / 180.0
    
    def self.style
      lambda do |style|
        style.add_element("ListStyle", "id" => "hideChildren") do |list_style|
          list_style.add_element("listItemType") { |type| type.text = "checkHideChildren" }
        end
      end
    end
    
    def self.lat_lon_box(bounds)
      lambda do |box|
        [ %w[west east south north], bounds.flatten ].transpose.each do |limit, value|
          box.add_element(limit) { |lim| lim.text = value }
        end
      end
    end
    
    def self.region(bounds, topmost = false)
      lambda do |region|
        region.add_element("Lod") do |lod|
          lod.add_element("minLodPixels") { |min| min.text = topmost ? 0 : TILE_SIZE / 2 }
          lod.add_element("maxLodPixels") { |max| max.text = -1 }
        end
        region.add_element("LatLonAltBox", &lat_lon_box(bounds))
      end
    end
    
    def self.network_link(bounds, path)
      lambda do |network|
        network.add_element("Region", &region(bounds))
        network.add_element("Link") do |link|
          link.add_element("href") { |href| href.text = path }
          link.add_element("viewRefreshMode") { |mode| mode.text = "onRegion" }
          link.add_element("viewFormat")
        end
      end
    end
    
    def self.build(map, ppi, image_path, kmz_path)
      wgs84_bounds = map.wgs84_bounds
      degrees_per_pixel = 180.0 * map.resolution_at(ppi) / Math::PI / EARTH_RADIUS
      dimensions = wgs84_bounds.map { |bound| bound.reverse.inject(:-) / degrees_per_pixel }
      max_zoom = Math::log2(dimensions.max).ceil - Math::log2(TILE_SIZE)
      topleft = [ wgs84_bounds.first.min, wgs84_bounds.last.max ]
      
      Dir.mktmppath do |temp_dir|
        file_name = image_path.basename
        source_path = temp_dir + file_name
        worldfile_path = temp_dir + "#{file_name}w"
        FileUtils.cp image_path, source_path
        map.write_world_file worldfile_path, map.resolution_at(ppi)
        
        pyramid = (0..max_zoom).to_a.with_progress("Resizing image pyramid:", 2, false).map do |zoom|
          resolution = degrees_per_pixel * 2**(max_zoom - zoom)
          degrees_per_tile = resolution * TILE_SIZE
          counts = wgs84_bounds.map { |bound| (bound.reverse.inject(:-) / degrees_per_tile).ceil }
          dimensions = counts.map { |count| count * TILE_SIZE }
          
          tfw_path = temp_dir + "zoom-#{zoom}.tfw"
          tif_path = temp_dir + "zoom-#{zoom}.tif"
          %x[convert -size #{dimensions.join ?x} canvas:none -type TrueColorMatte -depth 8 "#{tif_path}"]
          WorldFile.write topleft, resolution, 0, tfw_path
          
          %x[gdalwarp -s_srs "#{map.projection}" -t_srs "#{Projection.wgs84}" -r bilinear -dstalpha "#{source_path}" "#{tif_path}"]
          
          indices_bounds = [ topleft, counts, [ :+, :- ] ].transpose.map do |coord, count, increment|
            boundaries = (0..count).map { |index| coord.send increment, index * degrees_per_tile }
            [ boundaries[0..-2], boundaries[1..-1] ].transpose.map(&:sort)
          end.map do |tile_bounds|
            tile_bounds.each.with_index.to_a
          end.inject(:product).map(&:transpose).map do |tile_bounds, indices|
            { indices => tile_bounds }
          end.inject({}, &:merge)
          { zoom => indices_bounds }
        end.inject({}, &:merge)
        
        kmz_dir = temp_dir + map.name
        kmz_dir.mkdir
        
        pyramid.map do |zoom, indices_bounds|
          zoom_dir = kmz_dir + zoom.to_s
          zoom_dir.mkdir
          
          tif_path = temp_dir + "zoom-#{zoom}.tif"
          indices_bounds.map do |indices, tile_bounds|
            index_dir = zoom_dir + indices.first.to_s
            index_dir.mkdir unless index_dir.exist?
            tile_kml_path = index_dir + "#{indices.last}.kml"
            tile_png_name = "#{indices.last}.png"
            
            xml = REXML::Document.new
            xml << REXML::XMLDecl.new(1.0, "UTF-8")
            xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1") do |kml|
              kml.add_element("Document") do |document|
                document.add_element("Style", &style)
                document.add_element("Region", &region(tile_bounds, true))
                document.add_element("GroundOverlay") do |overlay|
                  overlay.add_element("drawOrder") { |draw_order| draw_order.text = zoom }
                  overlay.add_element("Icon") do |icon|
                    icon.add_element("href") { |href| href.text = tile_png_name }
                  end
                  overlay.add_element("LatLonBox", &lat_lon_box(tile_bounds))
                end
                if zoom < max_zoom
                  indices.map do |index|
                    [ 2 * index, 2 * index + 1 ]
                  end.inject(:product).select do |subindices|
                    pyramid[zoom + 1][subindices]
                  end.each do |subindices|
                    document.add_element("NetworkLink", &network_link(pyramid[zoom + 1][subindices], "../../#{[ zoom+1, *subindices ].join ?/}.kml"))
                  end
                end
              end
            end
            File.write tile_kml_path, xml
            
            tile_png_path = index_dir + tile_png_name
            crops = indices.map { |index| index * TILE_SIZE }
            %Q[convert "#{tif_path}" -quiet +repage -crop #{TILE_SIZE}x#{TILE_SIZE}+#{crops.join ?+} +repage +dither -type PaletteBilevelMatte PNG8:"#{tile_png_path}"]
          end
        end.flatten.with_progress("Creating tiles:", 2).each { |command| %x[#{command}] }
        
        xml = REXML::Document.new
        xml << REXML::XMLDecl.new(1.0, "UTF-8")
        xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1") do |kml|
          kml.add_element("Document") do |document|
            document.add_element("LookAt") do |look_at|
              range_x = map.extents.first / 2.0 / Math::tan(FOV) / Math::cos(TILT)
              range_y = map.extents.last / Math::cos(FOV - TILT) / 2 / (Math::tan(FOV - TILT) + Math::sin(TILT))
              names_values = [ %w[longitude latitude], map.projection.reproject_to_wgs84(map.centre) ].transpose
              names_values << [ "tilt", TILT * 180.0 / Math::PI ] << [ "range", 1.2 * [ range_x, range_y ].max ] << [ "heading", -map.rotation ]
              names_values.each { |name, value| look_at.add_element(name) { |element| element.text = value } }
            end
            document.add_element("Name") { |name| name.text = map.name }
            document.add_element("Style", &style)
            document.add_element("NetworkLink", &network_link(pyramid[0][[0,0]], "0/0/0.kml"))
          end
        end
        kml_path = kmz_dir + "doc.kml"
        File.write kml_path, xml
        
        temp_kmz_path = temp_dir + "#{map.name}.kmz"
        Dir.chdir(kmz_dir) { %x[#{ZIP} -r "#{temp_kmz_path}" *] }
        FileUtils.cp temp_kmz_path, kmz_path
      end
    end
  end
  
  module Raster
    def self.build(config, map, ppi, svg_path, temp_dir, png_path)
      dimensions = map.dimensions_at(ppi)
      rasterise = config["rasterise"]
      case rasterise
      when /inkscape/i
        %x["#{rasterise}" --without-gui --file="#{svg_path}" --export-png="#{png_path}" --export-width=#{dimensions.first} --export-height=#{dimensions.last} --export-background="#FFFFFF" #{DISCARD_STDERR}]
      when /batik/
        args = %Q[-d "#{png_path}" -bg 255.255.255.255 -m image/png -w #{dimensions.first} -h #{dimensions.last} "#{svg_path}"]
        jar_path = Pathname.new(rasterise).expand_path + "batik-rasterizer.jar"
        java = config["java"] || "java"
        %x[#{java} -jar "#{jar_path}" #{args}]
      when /rsvg-convert/
        %x["#{rasterise}" --background-color white --format png --output "#{png_path}" --width #{dimensions.first} --height #{dimensions.last} "#{svg_path}"]
      when "qlmanage"
        square_svg_path = temp_dir + "square.svg"
        square_png_path = temp_dir + "square.svg.png"
        xml = REXML::Document.new(svg_path.read)
        millimetres = map.extents.map { |extent| 1000.0 * extent / map.scale }
        xml.elements["/svg"].attributes["width"] = "#{millimetres.max}mm"
        xml.elements["/svg"].attributes["height"] = "#{millimetres.max}mm"
        xml.elements["/svg"].attributes["viewBox"] = "0 0 #{millimetres.max} #{millimetres.max}"
        File.write square_svg_path, xml
        %x[qlmanage -t -s #{dimensions.max} -o "#{temp_dir}" "#{square_svg_path}"]
        %x[convert "#{square_png_path}" -crop #{dimensions.join ?x}+0+0 +repage "#{png_path}"]
      when /phantomjs/i
        js_path = temp_dir + "rasterise.js"
        File.write js_path, %Q[
          var page = require('webpage').create();
          var sys = require('system');
          page.zoomFactor = parseFloat(sys.args[1]);
          page.viewportSize = { width: 1, height: 1 };
          page.open('#{svg_path}', function(status) {
              window.setTimeout(function() {
                  page.render('#{png_path}');
                  phantom.exit();
              }, 2000);
          });
        ]
        %x["#{rasterise}" "#{js_path}" 1.0]
        test_dimensions = %x[identify -format "%w,%h" "#{png_path}"].split(?,).map(&:to_f)
        index = dimensions[0] > dimensions[1] ? 0 : 1
        screen_ppi = (test_dimensions[index] * ppi / dimensions[index]).round
        zoom = ppi.to_f / screen_ppi
        %x["#{rasterise}" "#{js_path}" #{zoom}]
      else
        abort("Error: specify either phantomjs, inkscape or qlmanage as your rasterise method (see README).")
      end
      %x[mogrify -units PixelsPerInch -density #{ppi} -type TrueColor "#{png_path}"]
    end
  end
  
  module PDF
    def self.build(config, map, svg_path, temp_dir, pdf_path)
      rasterise = config["rasterise"]
      case rasterise
      when /inkscape/i
        %x["#{rasterise}" --without-gui --file="#{svg_path}" --export-pdf="#{pdf_path}" #{DISCARD_STDERR}]
      when /batik/
        jar_path = Pathname.new(rasterise).expand_path + "batik-rasterizer.jar"
        java = config["java"] || "java"
        %x[#{java} -jar "#{jar_path}" -d "#{pdf_path}" -bg 255.255.255.255 -m application/pdf "#{svg_path}"]
      when /rsvg-convert/
        %x["#{rasterise}" --background-color white --format pdf --output "#{pdf_path}" "#{svg_path}"]
      when "qlmanage"
        raise NoVectorPDF.new("qlmanage")
      when /phantomjs/
        xml = REXML::Document.new(svg_path.read)
        width, height = %w[width height].map { |name| xml.elements["/svg"].attributes[name] }
        js_path = temp_dir + "makepdf.js"
        File.write js_path, %Q[
          var page = require('webpage').create();
          var sys = require('system');
          page.paperSize = { width: '#{width}', height: '#{height}' };
          page.open('#{svg_path}', function(status) {
              window.setTimeout(function() {
                  page.render('#{pdf_path}');
                  phantom.exit();
              }, 2000);
          });
        ]
        %x["#{rasterise}" "#{js_path}"]
      else
        abort("Error: specify either inkscape or phantomjs as your rasterise method (see README).")
      end
    end
  end
  
  def self.run
    default_config = YAML.load(CONFIG)
    
    %w[bounds.kml bounds.gpx].map do |filename|
      Pathname.pwd + filename
    end.find(&:exist?).tap do |bounds_path|
      default_config["bounds"] = bounds_path if bounds_path
    end
    
    unless Pathname.new("nswtopo.cfg").expand_path.exist?
      if default_config["bounds"]
        puts "No nswtopo.cfg configuration file found. Using #{default_config['bounds'].basename} as map bounds."
      else
        abort "Error: could not find any configuration file (nswtopo.cfg) or bounds file (bounds.kml)."
      end
    end
    
    config = [ Pathname.new(__FILE__).realdirpath.dirname, Pathname.pwd ].map do |dir_path|
      dir_path + "nswtopo.cfg"
    end.select(&:exist?).map do |config_path|
      begin
        YAML.load config_path.read
      rescue ArgumentError, SyntaxError => e
        abort "Error in configuration file: #{e.message}"
      end
    end.inject(default_config, &:deep_merge)
    
    config["include"] = [ *config["include"] ]
    if config["include"].empty?
      config["include"] << "nsw/lpimap"
      puts "No layers specified. Adding nsw/lpimap by default."
    end
    
    %w[controls.gpx controls.kml].map do |filename|
      Pathname.pwd + filename
    end.find(&:file?).tap do |control_path|
      if control_path
        config["include"] |= [ "controls" ]
        config["controls"] ||= {}
        config["controls"]["path"] ||= control_path.to_s
      end
    end
    
    config["include"].unshift "canvas" if Pathname.new("canvas.png").expand_path.exist?
    
    map = Map.new(config)
    
    builtins = YAML.load %q[---
canvas:
  server:
    class: CanvasSource
relief:
  server:
    class: ReliefSource
    interval: 0.3
    tile_sizes: [ 1024, 1024 ]
  ext: png
  altitude: 45
  azimuth: 315
  exaggeration: 2
  resolution: 45.0
  opacity: 0.3
  highlights: 20
grid:
  server:
    class: GridSource
  interval: 1000
  width: 0.1
  colour: black
  label-spacing: 5
  fontsize: 7.8
  family: Arial Narrow
declination:
  server:
    class: DeclinationSource
  spacing: 1000
  width: 0.1
  colour: black
controls:
  server:
    class: ControlSource
  colour: "#880088"
  family: Arial
  fontsize: 14
  diameter: 7.0
  thickness: 0.2
  water-colour: blue
]
    
    sources = {}
    
    [ *config["import"] ].reverse.map do |file_or_hash|
      [ *file_or_hash ].flatten
    end.map do |file_or_path, label|
      [ Pathname.new(file_or_path).expand_path, label ]
    end.each do |path, label|
      label ||= path.basename(path.extname).to_s
      sources.merge! label => { "server" => { "class" => "ImportSource" }, "path" => path.to_s }
    end
    
    config["include"].map do |label_or_hash|
      [ *label_or_hash ].flatten
    end.each do |label, resolution|
      path = Pathname.new(label).expand_path
      layer_label, options = case
      when builtins[label]
        [ label, builtins[label] ]
      when %w[.kml .gpx].include?(path.extname.downcase) && path.file?
        options = YAML.load %Q[---
          server:
            class: OverlaySource
          width: 0.4
          colour: black
          opacity: 0.4
          path: #{path}
        ]
        [ path.basename(path.extname).to_s, options ]
      else
        yaml = [ Pathname.pwd, Pathname.new(__FILE__).realdirpath.dirname + "sources", URI.parse(GITHUB_SOURCES) ].map do |root|
          root + "#{label}.yml"
        end.inject(nil) do |memo, path|
          memo ||= path.read rescue nil
        end
        abort "Error: couldn't find source for '#{label}'" unless yaml
        [ label.gsub(?/, SEGMENT), YAML.load(yaml) ]
      end
      options.merge! "resolution" => resolution if resolution
      sources.merge! layer_label => options
    end
    
    sources.keys.select do |label|
      config[label]
    end.each do |label|
      sources[label].deep_merge! config[label]
    end
    
    sources["relief"]["clips"] = sources.map do |label, options|
      [ *options["relief-clips"] ].map { |sublabel| [ label, sublabel ].join SEGMENT }
    end.inject(&:+) if sources["relief"]
    
    config["contour-interval"].tap do |interval|
      interval ||= map.scale < 40000 ? 10 : 20
      # TODO: generalise this!
      abort "Error: invalid contour interval specified (must be 10 or 20)" unless [ 10, 20 ].include? interval
      sources.each do |label, options|
        options["exclude"] = [ *options["exclude"] ]
        [ *options["intervals-contours"] ].select do |candidate, sublayer|
          candidate != interval
        end.map(&:last).each do |sublayer|
          options["exclude"] << sublayer
        end
      end
    end
    
    sources.each do |label, options|
      server_options = options.delete "server"
      options["server"] = NSWTopo.const_get(server_options.delete "class").new(server_options)
    end
    
    config["exclude"] = [ *config["exclude"] ].map { |label| label.gsub ?/, SEGMENT }
    config["exclude"].each { |label| sources.delete label }
    
    puts "Map details:"
    puts "  name: #{map.name}"
    puts "  size: %imm x %imm" % map.extents.map { |extent| 1000 * extent / map.scale }
    puts "  scale: 1:%i" % map.scale
    puts "  rotation: %.1f degrees" % map.rotation
    puts "  extent: %.1fkm x %.1fkm" % map.extents.map { |extent| 0.001 * extent }
    
    sources.map do |label, options|
      [ label, options, options["server"].path(label, options) ]
    end.select do |label, options, path|
      path && !path.exist?
    end.recover(InternetError, ServerError, BadLayerError).each do |label, options, path|
      options["server"].download(label, options, map)
    end
    
    svg_name = "#{map.name}.svg"
    svg_path = Pathname.pwd + svg_name
    xml = svg_path.exist? ? REXML::Document.new(svg_path.read) : map.xml
    
    removals = config["exclude"].select do |label|
      xml.elements["/svg/g[@id='#{label}' or starts-with(@id,'#{label}#{SEGMENT}')]"]
    end
    
    updates = sources.reject do |label, options|
      xml.elements["/svg/g[@id='#{label}' or starts-with(@id,'#{label}#{SEGMENT}')]"] && FileUtils.uptodate?(svg_path, [ *options["server"].path(label, options) ])
    end
    
    Dir.mktmppath do |temp_dir|
      puts "Compositing layers to #{svg_name}:"
      tmp_svg_path = temp_dir + svg_name
      tmp_svg_path.open("w") do |file|
        updates.each do |label, options|
          before, after = sources.keys.inject([[]]) do |memo, candidate|
            candidate == label ? memo << [] : memo.last << candidate
            memo
          end
          neighbour = xml.elements.collect("/svg/g[@id]") do |sibling|
            sibling if after.any? do |after_label|
              sibling.attributes["id"] == after_label || sibling.attributes["id"].start_with?("#{after_label}#{SEGMENT}")
            end
          end.compact.first
          begin
            options["server"].render_svg(xml, label, options, map) do |layer|
              neighbour ? xml.elements["/svg"].insert_before(neighbour, layer) : xml.elements["/svg"].add_element(layer)
            end
          rescue BadLayerError => e
            puts "Failed to render #{label}: #{e.message}"
          end
        end
        
        removals.each do |label|
          puts "  Removing #{label}"
          xml.elements.each("/svg/g[@id='#{label}' or starts-with(@id,'#{label}#{SEGMENT}')]", &:remove)
        end
        
        updates.each do |label, options|
          [ %w[below insert_before 1 to_a], %w[above insert_after last() reverse] ].select do |position, insert, predicate, order|
            config[position]
          end.each do |position, insert, predicate, order|
            config[position].select do |target_label, sibling_label|
              target_label == label || target_label.start_with?("#{label}#{SEGMENT}")
            end.each do |target_label, sibling_label|
              sibling = xml.elements["/svg/g[@id='#{sibling_label}' or starts-with(@id,'#{sibling_label}#{SEGMENT}')][#{predicate}]"]
              xml.elements.collect("/svg/g[@id='#{target_label}' or starts-with(@id,'#{target_label}#{SEGMENT}')]") do |layer|
                layer
              end.send(order).each do |layer|
                puts "  Moving #{layer.attributes['id']} #{position} #{sibling.attributes['id']}"
                layer.parent.send insert, sibling, layer
              end if sibling
            end
          end
        end
        
        xml.elements.each("/svg/g[*]") { |layer| layer.add_attribute("inkscape:groupmode", "layer") }
        
        if config["check-fonts"]
          fonts_needed = xml.elements.collect("//[@font-family]") do |element|
            element.attributes["font-family"].gsub(/[\s\-\'\"]/, "")
          end.uniq
          fonts_present = %x[identify -list font].scan(/(family|font):(.*)/i).map(&:last).flatten.map do |family|
            family.gsub(/[\s\-]/, "")
          end.uniq
          fonts_missing = fonts_needed - fonts_present
          if fonts_missing.any?
            puts "Your system does not include some fonts used in #{svg_name}. (Inkscape will not render these fonts correctly.)"
            fonts_missing.sort.each { |family| puts "  #{family}" }
          end
        end
        
        if config["pretty"]
          formatter = REXML::Formatters::Pretty.new
          formatter.compact = true
          formatter.write xml.root, file
        else
          xml.write file
        end
      end
      FileUtils.cp tmp_svg_path, svg_path
    end if updates.any? || removals.any?
    
    formats = [ *config["formats"] ].map { |format| [ *format ].flatten }.inject({}) { |memo, (format, option)| memo.merge format => option }
    formats["prj"] = %w[wkt_all proj4 wkt wkt_simple wkt_noct wkt_esri mapinfo xml].delete(formats["prj"]) || "proj4" if formats.include? "prj"
    formats["png"] ||= nil if formats.include? "map"
    (formats.keys & %w[png tif gif jpg kmz]).each do |format|
      formats[format] ||= config["ppi"]
      formats["#{format[0]}#{format[2]}w"] = formats[format] if formats.include? "prj"
    end
    
    outstanding = (formats.keys & %w[png tif gif jpg kmz pdf pgw tfw gfw jgw map prj]).reject do |format|
      FileUtils.uptodate? "#{map.name}.#{format}", [ svg_path ]
    end
    
    Dir.mktmppath do |temp_dir|
      puts "Generating requested output formats:"
      outstanding.group_by do |format|
        formats[format]
      end.each do |ppi, group|
        raster_path = temp_dir + "#{map.name}.#{ppi}.png"
        if (group & %w[png tif gif jpg kmz]).any? || (ppi && group.include?("pdf"))
          dimensions = map.dimensions_at(ppi)
          puts "  Generating raster: %ix%i (%.1fMpx) @ %i ppi" % [ *dimensions, 0.000001 * dimensions.inject(:*), ppi ]
          Raster.build config, map, ppi, svg_path, temp_dir, raster_path
        end
        group.each do |format|
          begin
            puts "  Generating #{map.name}.#{format}"
            output_path = temp_dir + "#{map.name}.#{format}"
            case format
            when "png"
              FileUtils.cp raster_path, output_path
            when "tif"
              tfw_path = Pathname.new("#{raster_path}w")
              map.write_world_file tfw_path, map.resolution_at(ppi)
              %x[gdal_translate -a_srs "#{map.projection}" -co "PROFILE=GeoTIFF" -co "COMPRESS=LZW" -mo "TIFFTAG_RESOLUTIONUNIT=2" -mo "TIFFTAG_XRESOLUTION=#{ppi}" -mo "TIFFTAG_YRESOLUTION=#{ppi}" "#{raster_path}" "#{output_path}"]
            when "gif", "jpg"
              %x[convert "#{raster_path}" "#{output_path}"]
            when "kmz"
              KMZ.build map, ppi, raster_path, output_path
            when "pdf"
              ppi ? %x[convert "#{raster_path}" "#{output_path}"] : PDF.build(config, map, svg_path, temp_dir, output_path)
            when "pgw", "tfw", "gfw", "jgw"
              map.write_world_file output_path, map.resolution_at(ppi)
            when "map"
              map.write_oziexplorer_map output_path, map.name, "#{map.name}.png", formats["png"]
            when "prj"
              File.write output_path, map.projection.send(formats["prj"])
            end
            FileUtils.cp output_path, Dir.pwd
          rescue NoVectorPDF => e
            puts "Error: can't generate vector PDF with #{e.message}. Specify a ppi for the PDF or use inkscape. (See README.)"
          end
        end
      end
    end unless outstanding.empty?
  end
end

Signal.trap("INT") do
  abort "\nHalting execution. Run the script again to resume."
end

if File.identical?(__FILE__, $0)
  NSWTopo.run
end

# TODO: move Source#download to main script, change NoDownload to raise in get_source, extract ext from path?
# TODO: switch to Open3 for shelling out
# TODO: split LPIMapLocal roads into sealed & unsealed?
# TODO: change scale instead of using expand-glyph where possible
# TODO: add option for absolute measurements for rerendering?
# TODO: add nodata transparency in vegetation source?
# TODO: add include: option for ArcGIS sublayers?
# TODO: Add import layers as per controls/overlays/etc?
# TODO: change include: layer list to a hash?

# # later:
# TODO: remove linked images from PDF output?
# TODO: put glow on control labels?
# TODO: add Relative_Height to topographic layers?
# TODO: find source for electricity transmission lines

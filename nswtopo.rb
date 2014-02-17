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

class REXML::Element
  alias_method :unadorned_add_element, :add_element
  def add_element(name, attrs = {})
    unadorned_add_element(name, attrs).tap do |element|
      yield element if block_given?
    end
  end
  
  def delete_self
    parent.delete_element(self)
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
      when Array then point_or_points.map { |point| reproject_to target, point }
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
        layer.parent.elements.collect("//g[@id='#{sublayer}']//path[@fill-rule='evenodd']") { |path| path }
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
      
      layer = xml.elements["/svg/g[@id='#{label}']"] || REXML::Element.new("g").tap(&block)
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
      layer.elements.each("./defs[not(*)]", &:delete_self)
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
    
    def rerender(element, command, values)
      element.elements.each(".//path") do |path|
        path.add_attribute "stroke-dasharray", [ *values ].join(?\s)
      end if command == "dash"
      xpaths = case command
      when "opacity"
        "self::/@style"
      when "expand"
        %w[stroke-width stroke-dasharray stroke-miterlimit font-size].map { |name| ".//[@#{name}]/@#{name}" }
      when "stretch"
        ".//[@stroke-dasharray]/@stroke-dasharray"
      when "colour"
        %w[stroke fill].map do |name|
          case values
          when Hash
            values.keys.map { |colour| ".//[@#{name}='#{colour}']/@#{name}" }
          else
            ".//[@#{name}!='none']/@#{name}"
          end
        end.flatten
      end
      [ *xpaths ].each do |xpath|
        REXML::XPath.each(element, xpath) do |attribute|
          attribute.normalized = case command
          when "opacity"
            "opacity:#{values}"
          when "expand", "stretch"
            attribute.value.split(/,\s*/).map(&:to_f).map { |size| size * values }.join(", ")
          when "colour"
            case values
            when Hash
              values[attribute.value] || attribute.value
            when String
              values
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
      source = REXML::Document.new(path(label, options).read)
      
      if xml.elements.each("/svg/g[starts-with(@id,'#{label}')]") do |layer|
        id = layer.attributes["id"]
        layer.replace_with source.elements["/svg/g[@id='#{id}']"]
      end.empty?
        source.elements.each("/svg/g[starts-with(@id,'#{label}')]", &block)
      end
      
      xml.elements.each("/svg/g[starts-with(@id,'#{label}') and *]") do |layer|
        id = layer.attributes["id"]
        name = id.split(SEGMENT).last
        puts "  Rendering #{id}"
        render_sources = (options["equivalences"] || {}).select do |group, names|
          names.include? name
        end.map(&:first) << name
        render_sources.inject(options) do |memo, key|
          memo.deep_merge(options[key] || {})
        end.select do |command, values|
          %w[opacity expand stretch colour dash].include? command
        end.each do |command, values|
          rerender(layer, command, values)
        end
      end
      
      xml.elements.each("/svg/defs[starts-with(@id,'#{label}')]", &:delete_self)
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
      service = HTTP.get(service_uri(options, "f" => "json"), params["headers"]) do |response|
        JSON.parse(response.body).tap do |result|
          raise ServerError.new(result["error"]["message"]) if result["error"]
        end
      end
      service["layers"].each { |layer| layer["name"].gsub! ?\s, ?_ }
      
      layer_order = service["layers"].reverse.map.with_index { |layer, index| { layer["name"] => index } }.inject({}, &:merge)
      layer_names = service["layers"].map { |layer| layer["name"] }
      
      resolution = resolution_for label, options, map
      transform = map.svg_transform(1000.0 * resolution / map.scale)
      tile_list = tiles(map, resolution, 3) # TODO: margin of 3 means what?
      
      downloads = %w[layers labels].select do |type|
        options[type]
      end.map do |type|
        scales_layers = case options[type]
        when Hash
          case type
          when "layers" then options[type]
          when "labels" then options[type].map { |multiplier, layers| [ map.scale * multiplier, layers ] }
          end
        when String, Array
          { options["scale"] => [ *options[type] ] }
        when true
          { options["scale"] => [] }
        end
        [ type, scales_layers ]
      end.map do |type, scales_layers|
        scales_layers.map do |scale, layers|
          dpi = ((scale || map.scale) * 0.0254 / resolution).floor
          scale = dpi * resolution / 0.0254
          ids, layer_defs = layers.map do |name, definition|
            name.is_a?(Hash) ? name.first : [ name, definition ]
          end.map do |name, definition|
            id = service["layers"].find { |layer| layer["name"] == name }.fetch("id")
            layer_def = "#{id}:#{definition}" if definition
            [ id, layer_def ]
          end.transpose
          layer_options = { "dpi" => dpi, "wkt" => map.projection.wkt_esri, "format" => "svg" }
          layer_options.merge!("layers" => "show:#{ids.join ?,}") if ids && ids.any?
          layer_options.merge!("layerDefs" => layer_defs.compact.join(?;)) if layer_defs && layer_defs.compact.any?
          xpath = type == "layers" ?
            "/svg//g[@id!='Labels' and not(.//g[@id])]" :
            "/svg//g[@id='Labels']"
          [ scale, layer_options, type, xpath ]
        end
      end.inject(:+)
      
      tilesets = tile_list.with_progress("Downloading: #{label}").map do |tile_bounds, tile_sizes, tile_offsets|
        tileset = downloads.map do |scale, layer_options, type, xpath|
          sleep params["interval"] if params["interval"]
          
          tile_xml = get_tile(tile_bounds, tile_sizes, options.merge(layer_options)) do |tile_data|
            tile_data.gsub! /ESRITransportation\&?Civic/, %Q['ESRI Transportation &amp; Civic']
            tile_data.gsub!  /ESRIEnvironmental\&?Icons/, %Q['ESRI Environmental &amp; Icons']
            tile_data.gsub! /Arial\s?MT/, "Arial"
            tile_data.gsub! "ESRISDS1.951", %Q['ESRI SDS 1.95 1']
          
            [ /id="(\w+)"/, /url\(#(\w+)\)"/, /xlink:href="#(\w+)"/ ].each do |regex|
              tile_data.gsub! regex do |match|
                case $1
                when "Labels", service["mapName"], *layer_names then match
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
          
          [ tile_xml, scale, type, xpath]
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
      
      layers = tilesets.find(lambda { [ [ ] ] }) do |tileset, _|
        tileset.all? { |tile_xml, _, _, xpath| tile_xml.elements[xpath] }
      end.first.map do |tile_xml, _, _, xpath|
        tile_xml.elements.collect(xpath) do |layer|
          name = layer.attributes["id"]
          opacity = layer.parent.attributes["opacity"] || 1
          [ name, opacity ]
        end
      end.inject([], &:+).uniq(&:first).sort_by do |name, _|
        layer_order[name] || layer_order.length
      end.map do |name, opacity|
        { name => xml.elements["/svg"].add_element("g",
          "id" => [ label, name ].join(SEGMENT),
          "style" => "opacity:#{opacity}",
          "transform" => transform,
        )}
      end.inject({}, &:merge)
      
      tilesets.with_progress("Assembling: #{label}").each do |tileset, tile_offsets|
        tileset.each do | tile_xml, scale, type, xpath|
          tile_xml.elements.collect(xpath) do |layer|
            [ layer, layer.attributes["id"] ]
          end.select do |layer, id|
            layers[id]
          end.each do |layer, id|
            tile_transform = "translate(#{tile_offsets.join ?\s})"
            clip_path = "url(##{[ label, 'tile', *tile_offsets ].join(SEGMENT)})"
            layers[id].add_element("g", "transform" => tile_transform, "clip-path" => clip_path) do |tile|
              case type
              when "layers"
                rerender(layer, "expand", map.scale.to_f / scale) if scale
              when "labels"
                layer.elements.each(".//pattern | .//path | .//font", &:delete_self)
                layer.deep_clone.tap do |copy|
                  copy.elements.each(".//text") { |text| text.add_attributes("stroke" => "white", "opacity" => 0.75) }
                end.elements.each { |element| tile << element }
              end
              layer.elements.each { |element| tile << element }
            end
          end
        end
      end
      
      xml.elements.each("//path[@d='']", &:delete_self)
      until xml.elements.each("/svg/g[@id]//g[not(*)]", &:delete_self).empty? do
      end
      xml.elements["//defs"].delete_self unless xml.elements["/svg/g[*]"]
      
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
      
      low, high = options["spot5"].values_at("low", "high")
      fx = [ *(100..200), *(6..10) ].inject(0.0) do |memo, n|
        "j==#{n} ? %.5f : (#{memo})" % case n
        # mappings for SPOT5 woody extent and foliage projective cover (FPC) (5-10m) 2011:
        when 100 then 0.0
        when 101..200 then n - 100 < low ? 0.0 : n - 100 > high ? 1.0 : (n - 100 - low).to_f / (high - low)
        # mappings for NSW Interim Native Vegetation Extent (2008-v2):
        when 6..7 then 0.6
        when 8..10 then 1.0
        else 0.0
        end
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
      layer = xml.elements["/svg/g[@id='#{label}']"] || REXML::Element.new("g").tap(&block)
      layer.add_attributes "id" => label, "style" => "opacity:#{opacity}", "transform" => map.svg_transform(1)
      draw(layer, options, map) do |coords, projection|
        easting, northing = projection.reproject_to(map.projection, coords)
        [ easting - map.bounds.first.first, map.bounds.last.last - northing ].map do |metres|
          1000.0 * metres / map.scale
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
        line.map { |point| yield point, projection }
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
      (projection.reproject_to_wgs84(coords).first / 6).floor + 31
    end
    
    def draw(group, options, map)
      interval = options["interval"]
      label_spacing = options["label-spacing"]
      label_interval = label_spacing * interval
      fontfamily = options["family"]
      fontsize = 25.4 * options["fontsize"] / 72.0
      strokewidth = options["width"]
      
      map.bounds.inject(:product).map do |corner|
        GridSource.zone(corner, map.projection)
      end.inject do |range, zone|
        [ *range, zone ].min .. [ *range, zone ].max
      end.each do |zone|
        projection = Projection.utm(zone)
        eastings, northings = map.transform_bounds_to(projection).map do |bound|
          (bound[0] / interval).floor .. (bound[1] / interval).ceil
        end.map do |counts|
          counts.map { |count| count * interval }
        end
        grid = eastings.map do |easting|
          northings.reverse.map do |northing|
            [ easting, northing ]
          end.map do |coords|
            [ GridSource.zone(coords, projection) == zone, coords ]
          end
        end
        [ grid, grid.transpose ].each.with_index do |gridlines, index|
          gridlines.each do |gridline|
            line = gridline.select(&:first).map(&:last)
            line.map do |coords|
              yield coords, projection
            end.map do |point|
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
            when :triangle
              points = [ -90, -210, -330 ].map do |angle|
                [ radius, 0 ].rotate_by(angle * Math::PI / 180.0)
              end.map { |vertex| vertex.join ?, }.join ?\s
              rotated.add_element("polygon", "points" => points, "fill" => "none", "stroke" => colour, "stroke-width" => strokewidth)
            when :water
              rotated.add_element("text", "dy" => 0.5 * radius, "font-family" => "Wingdings", "fill" => "none", "stroke" => "blue", "stroke-width" => strokewidth, "text-anchor" => "middle", "font-size" => 2 * radius) do |text|
                text.add_text "S"
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
      width = options["width"] || params["width"]
      colour = options["colour"] || params["colour"]
      gps = GPS.new Pathname.new(options["path"]).expand_path
      [ [ :tracks, "polyline", { "fill" => "none", "stroke" => colour, "stroke-width" => width } ],
        [ :areas, "polygon", { "fill" => colour, "stroke" => "none" } ]
      ].each do |feature, element, attributes|
        gps.send(feature).each do |list, name|
          points = list.map { |coords| yield(coords, Projection.wgs84).join ?, }.join ?\s
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
    %w[controls.kml controls.gpx].map do |filename|
      Pathname.pwd + filename
    end.find(&:exist?).tap do |control_path|
      default_config["controls"] = { "path" => control_path.to_s } if control_path
    end
    
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
    config["exclude"] = [ *config["exclude"] ]
    config["formats"] = [ *config["formats"] ]
    
    map = Map.new(config)
    
    servers = YAML.load %q[---
sixmaps:
  class: ArcGIS
  host: maps.six.nsw.gov.au
  folder: sixmaps
  tile_sizes: [ 2048, 2048 ]
  interval: 0.1
flex2:
  class: ArcGIS
  host: spatialprod.dpi.nsw.gov.au
  instance: ArcGIS2
  folder: IndustryViewFLEX2
  tile_sizes: [ 2048, 2048 ]
  interval: 0.1
atlas:
  class: ArcGIS
  host: atlas.nsw.gov.au
  instance: arcgis1
  cookie: http://atlas.nsw.gov.au/
  tile_sizes: [ 2048, 2048 ]
  interval: 0.1
lpi_ortho:
  class: LPIOrthoServer
  host: lite.maps.nsw.gov.au
  tile_size: 1024
  interval: 1.0
  projection: +proj=lcc +lat_1=-30.75 +lat_2=-35.75 +lat_0=-33.25 +lon_0=147 +x_0=9300000 +y_0=4500000 +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs
nokia_maps:
  class: TiledMapServer
  uri: http://m.ovi.me/?c=${latitude},${longitude}&t=${name}&z=${zoom}&h=${vsize}&w=${hsize}&f=${format}&nord&nodot
  projection: +proj=merc +lon_0=0 +k=1 +x_0=0 +y_0=0 +a=6378137 +b=6378137 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs
  tile_sizes: [ 1024, 1024 ]
  interval: 1.2
  crops: [ [ 0, 0 ], [ 26, 0 ] ]
  tile_limit: 250
  retries_on_blank: 1
google_maps:
  class: TiledMapServer
  uri: http://maps.googleapis.com/maps/api/staticmap?zoom=${zoom}&size=${hsize}x${vsize}&scale=1&format=${format}&maptype=${name}&sensor=false&center=${latitude},${longitude}
  projection: +proj=merc +lon_0=0 +k=1 +x_0=0 +y_0=0 +a=6378137 +b=6378137 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs
  tile_sizes: [ 640, 640 ]
  interval: 1.2
  crops: [ [ 0, 0 ], [ 30, 0 ] ]
  tile_limit: 250
relief:
  class: ReliefSource
  interval: 0.3
  tile_sizes: [ 1024, 1024 ]
declination:
  class: DeclinationSource
controls:
  class: ControlSource
grid:
  class: GridSource
canvas:
  class: CanvasSource
import:
  class: ImportSource
vegetation:
  class: VegetationSource
overlay:
  class: OverlaySource
  width: 0.5
  colour: black
  opacity: 0.3
]
    servers = servers.inject({}) do |memo, (name, params)|
      source = NSWTopo.const_get(params.delete "class").new(params)
      memo.merge name => source
    end
    
    sources = YAML.load %q[---
reference-topo-current:
  server: sixmaps
  service: LPITopoMap
  ext: png
  resolution: 2.0
  background: white
reference-topo-s1:
  server: sixmaps
  service: LPITopoMap_S1
  ext: png
  resolution: 2.0
  background: white
reference-topo-s2:
  server: lpi_ortho
  image: /OTDF_Imagery/NSWTopoS2v2.ecw
  otdf: true
  ext: png
  resolution: 4.0
aerial-lpi-eastcoast:
  server: lpi_ortho
  image: /Imagery/lr94ortho1m.ecw
  ext: jpg
aerial-google:
  server: google_maps
  name: satellite
  format: jpg
  ext: jpg
aerial-nokia:
  server: nokia_maps
  name: 1
  format: 1
  ext: jpg
aerial-lpi-ads40:
  server: lpi_ortho
  config: /ADS40ImagesConfig.js
  ext: jpg
aerial-best:
  server: sixmaps
  service: LPI_Imagery_Best
  ext: jpg
  resolution: 1.0
vegetation:
  server: vegetation
  resolution: 25.0
  colour:
    woody: light green
    non-woody: white
  spot5:
    low: 0
    high: 80
canvas:
  server: canvas
  ext: png
plantation:
  server: atlas
  folder: atlas
  service: Economy_Forestry
  resolution: 0.55
  layers:
    ~:
      Forestry: Classification='Plantation forestry'
  ext: svg
  opacity: 1
  colour: "#80D19B"
alt-contours-10m:
  server: flex2
  service: Topography
  ext: svg
  layers: 
    25000:
      Contour: sourceprogram_code <> 2 AND (elevation % 10 = 0) AND elevation > 0
  colour: "#805100"
  expand: 0.28
alt-contours-20m:
  server: flex2
  service: Topography
  ext: svg
  layers: 
    25000:
      Contour: sourceprogram_code <> 2 AND (elevation % 20 = 0) AND elevation > 0
  colour: "#805100"
  expand: 0.28
alt-contours-index:
  server: flex2
  service: Topography
  ext: svg
  layers: 
    25000:
      Contour: sourceprogram_code <> 2 AND (elevation % 100 = 0) AND elevation > 0
  labels:
    0.5:
      Contour: sourceprogram_code <> 2 AND (elevation % 100 = 0) AND elevation > 0
  Contour:
    colour: "#805100"
    expand: 0.63
alt-cadastre:
  server: flex2
  service: Lots
  ext: svg
  layers:
    25000:
      - Boundary
  opacity: 0.5
  colour: "#777777"
  expand: 0.5
alt-creeks:
  server: flex2
  service: Base_Mapping
  ext: svg
  layers:
    25000:
      Other_Streams_and_Tributaries: relevance >= 8
  colour: "#4985DF"
  expand: 0.4
  dash: ~
alt-streams:
  server: flex2
  service: Base_Mapping
  ext: svg
  layers:
    25000:
      Other_Streams_and_Tributaries: relevance >= 5 AND relevance < 8
  colour: "#4985DF"
  expand: 0.7
  dash: ~
alt-rivers:
  server: flex2
  service: Base_Mapping
  ext: svg
  layers:
    25000:
      Other_Streams_and_Tributaries: relevance < 5
  colour: "#4985DF"
  dash: ~
  expand: 1.5
alt-paths:
  server: flex2
  service: Base_Mapping
  ext: svg
  layers:
    ~:
      Other_Access_Roads_and_Tracks: functionhierarchy_code = 9
  colour: black
  expand: 0.6
  dash: 3.5
alt-vehicular-tracks:
  server: flex2
  service: Base_Mapping
  ext: svg
  layers:
    ~:
      Other_Access_Roads_and_Tracks: functionhierarchy_code = 8
  colour: darkorange
  dash: 6 2
alt-unsealed-roads:
  server: flex2
  service: Base_Mapping
  ext: svg
  layers:
    25000:
      Highways: surface_code >= 2
      Regional_Roads: surface_code >= 2
      Major_Roads: surface_code >= 2
      Minor_Roads: surface_code >= 2
      Other_Access_Roads_and_Tracks: functionhierarchy_code in ( 5, 6, 7 ) AND surface_code >= 2
  colour: darkorange
alt-sealed-roads:
  server: flex2
  service: Base_Mapping
  ext: svg
  layers:
    25000:
      Highways: surface_code < 2 OR surface_code IS NULL
      Regional_Roads: surface_code < 2 OR surface_code IS NULL
      Major_Roads: surface_code < 2 OR surface_code IS NULL
      Minor_Roads: surface_code < 2 OR surface_code IS NULL
      Other_Access_Roads_and_Tracks: functionhierarchy_code in ( 5, 6, 7 ) AND (surface_code < 2 OR surface_code IS NULL)
  colour: red
alt-labels:
  server: flex2
  service: Base_Mapping
  ext: svg
  labels:
    0.7:
      - Major_Rivers
      - Other_Streams_and_Tributaries
      - Highways
      - Regional_Roads
      - Major_Roads
      - Minor_Roads
      - Other_Access_Roads_and_Tracks
# alt-labels:
#   server: sixmaps
#   service: LPI_RasterLabels_1
#   ext: svg
#   labels:
#     0.6:
#     - Raster_Road_Labels
#     - Raster_Place_Labels
#     - Cities
#     - Towns
#     - Villages
#     - Localities
#     - Suburbs
#   colour:
#     "#FFFFFF": black
#     "#CCCCCC": black
#   opacity: 0.8
topographic:
  server: sixmaps
  service: LPIMap
  resolution: 0.55
  ext: svg
  layers:
    4500:
      Roads_onbridge_LS: functionhierarchy = 9 AND roadontype = 2
      Roads_onground_LS: functionhierarchy = 9 AND roadontype = 1
    9000:
    - Roads_Urban_MS
    - Roads_intunnel_MS
    - Bridge_Ford_Names
    - Gates_Grids
    - Dwellings_Buildings
    - Building_Large
    - Homestead_Tourism_Major
    - Lot
    - Property
    - Contour_10m
    - Beacon_Tower
    - Wharfs_Ramps
    - Damwall_Racetrack
    - StockDams
    - Creek_Named
    - Creek_Unnamed
    - Stream_Unnamed
    - Stream_Named
    - Stream_Main
    - River_Main
    - River_Major
    - HydroArea: perenniality < 2 OR perenniality IS NULL
    - Oceans_Bays
    11000:
    - Contour_20m
    ~:
    - PlacePoint_LS
    - Caves_Pinnacles
    - Ridge_Beach
    - Waterfalls_springs
    - Swamps_LSI
    - Cliffs_Reefs_Mangroves
    - CliffTop_Levee
    - PointOfInterest
    - Tourism_Minor
    - Railway_MS
    - Railway_intunnel_MS
    - Runway
    - Airport_Station
    - State_Border
  labels:
    0.6:
    - Roads_Urban_MS
    - Roads_intunnel_MS
    - Homestead_Tourism_Major
    - Contour_20m
    - Beacon_Tower
    - Wharfs_Ramps
    - Damwall_Racetrack
    - StockDams
    - Creek_Named
    - Creek_Unnamed
    - Stream_Names
    - Stream_Unnamed
    - Stream_Named
    - Stream_Main
    - River_Main
    - River_Major
    - HydroArea: perenniality < 2 OR perenniality IS NULL
    - Oceans_Bays
    - PlacePoint_LS
    - Caves_Pinnacles
    - Ridge_Beach
    - Waterfalls_springs
    - Swamps_LSI
    - Cliffs_Reefs_Mangroves
    - CliffTop_Levee
    - PointOfInterest
    - Tourism_Minor
    - Railway_MS
    - Railway_intunnel_MS
    - Runway
    - Airport_Station
    - State_Border
  equivalences:
    contours:
    - Contour_10m
    - Contour_20m
    water:
    - StockDams
    - Creek_Named
    - Creek_Unnamed
    - Stream_Unnamed
    - Stream_Named
    - Stream_Main
    - River_Main
    - River_Major
    - HydroArea
    - Oceans_Bays
    pathways:
    - Roads_onground_LS
    - Roads_onbridge_LS
    roads:
    - Roads_Urban_MS
    - Roads_intunnel_MS
    cadastre:
    - Lot
    - Property
    text:
    - Labels
  pathways:
    expand: 0.5
    colour: 
      "#A39D93": "#363636"
  contours:
    expand: 0.7
    colour: "#805100"
  roads:
    expand: 0.6
    colour:
      "#A39D93": "#363636"
      "#9C9C9C": "#363636"
  cadastre:
    expand: 0.5
    opacity: 0.5
    colour: "#777777"
  text: 
    colour: 
      "#A87000": "#000000"
      "#FAFAFA": "#444444"
  water:
    opacity: 1
    colour:
      "#73A1E6": "#4985DF"
  Creek_Named:
    expand: 0.3
  Creek_Unnamed:
    expand: 0.3
  Stream_Named:
    expand: 0.5
  Stream_Unnamed:
    expand: 0.5
  Stream_Main:
    expand: 0.7
  River_Main:
    expand: 0.7
  River_Major:
    expand: 0.7
  HydroArea:
    expand: 0.5
  PointOfInterest:
    expand: 0.6
  Tourism_Minor:
    expand: 0.6
  Gates_Grids:
    expand: 0.5
  Beacon_Tower:
    expand: 0.5
relief:
  server: relief
  clips:
  - topographic.HydroArea
  - topographic.Oceans_Bays
  ext: png
  altitude: 45
  azimuth: 315
  exaggeration: 2
  resolution: 45.0
  opacity: 0.3
  highlights: 20
holdings:
  server: atlas
  folder: sixmaps
  service: _LHPA
  ext: svg
  layers:
  - Holdings
  labels:
  - Holdings
  colour:
    "#B0A100": "#FF0000"
    "#948800": "#FF0000"
grid:
  server: grid
  interval: 1000
  width: 0.1
  colour: black
  label-spacing: 5
  fontsize: 7.8
  family: Arial Narrow
declination:
  server: declination
  spacing: 1000
  width: 0.1
  colour: black
controls:
  server: controls
  colour: "#880088"
  family: Arial
  fontsize: 14
  diameter: 7.0
  thickness: 0.2
  water-colour: blue
]
    
    config["contour-interval"].tap do |interval|
      interval ||= map.scale < 40000 ? 10 : 20
      abort "Error: invalid contour interval specified (must be 10 or 20)" unless [ 10, 20 ].include? interval
      sources["topographic"]["layers"].each do |scale, layers|
        [ 10, 20, 50 ].each do |value|
          layers.delete "Contour_#{value}m" unless value == interval
        end
      end.reject! { |scale, layers| layers.empty? }
      [ 10, 20, 50 ].each do |value|
        sources.delete "alt-contours-#{value}m" unless value == interval
      end
    end
    
    includes = %w[topographic]
    includes << "canvas" if Pathname.new("canvas.png").expand_path.exist?
    
    (config["import"] || []).reverse.map do |file_or_hash|
      [ *file_or_hash ].flatten
    end.map do |file_or_path, label|
      [ Pathname.new(file_or_path).expand_path, label ]
    end.each do |path, label|
      label ||= path.basename(path.extname).to_s
      sources = { label => { "server" => "import", "path" => path.to_s } }.merge sources
      includes << label
    end
    
    (config["overlays"] || {}).map do |file_or_path, options|
      [ Pathname.new(file_or_path).expand_path, options ]
    end.each do |path, options|
      label = path.basename(path.extname).to_s
      sources.merge! label => (options || {}).merge("server" => "overlay", "path" => path.to_s)
      includes << label
    end
    
    includes << "controls" if config["controls"] && config["controls"]["path"]

    sources.keys.select do |label|
      config[label]
    end.each do |label|
      sources[label].deep_merge! config[label]
    end
    
    sources.each do |label, options|
      options["server"] = servers[options.delete "server"]
    end
    
    includes += config["include"]
    includes.map! { |label_or_hash| [ *label_or_hash ].flatten }
    sources.each do |label, options|
      includes.each { |match, resolution| options.merge!("resolution" => resolution) if label[match] && resolution }
    end
    
    excludes = config["exclude"]
    
    labels = sources.keys
    sources.select! { |label, options| includes.any? { |match, _| label[match] } }
    sources.reject! { |label, options| excludes.any? { |match| label[match] } }
    
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
    
    removals = labels.select do |label|
      excludes.any? { |match| label[match] }
    end.select do |label|
      xml.elements["/svg/g[starts-with(@id,'#{label}')]"]
    end
    
    updates = sources.reject do |label, options|
      xml.elements["/svg/g[starts-with(@id,'#{label}')]"] && FileUtils.uptodate?(svg_path, [ *options["server"].path(label, options) ])
    end
    
    Dir.mktmppath do |temp_dir|
      puts "Compositing layers to #{svg_name}:"
      tmp_svg_path = temp_dir + svg_name
      tmp_svg_path.open("w") do |file|
        updates.each do |label, options|
          before, after = labels.inject([[]]) do |memo, candidate|
            candidate == label ? memo << [] : memo.last << candidate
            memo
          end
          neighbour = xml.elements.collect("/svg/g[@id]") do |sibling|
            sibling if after.any? { |after_label| sibling.attributes["id"].start_with? after_label }
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
          xml.elements.each("/svg/g[starts-with(@id,'#{label}')]", &:delete_self)
        end
        
        xml.elements.each("/svg/g[*]") { |layer| layer.add_attribute("inkscape:groupmode", "layer") }
        
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
    
    formats = config["formats"].map { |format| [ *format ].flatten }.inject({}) { |memo, (format, option)| memo.merge format => option }
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

# # later:
# TODO: remove linked images from PDF output?
# TODO: put glow on control labels?
# TODO: add Relative_Height to topographic layers?
# TODO: find source for electricity transmission lines

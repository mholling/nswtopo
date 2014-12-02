#!/usr/bin/env ruby

# Copyright 2011-2014 Matthew Hollingworth
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

GITHUB_SOURCES = "https://github.com/mholling/nswtopo/raw/master/sources/"

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
    reject { |key, value| value.nil? }.map { |key, value| "#{key}=#{value}" }.join ?&
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
  
  def rotate_by_degrees(angle)
    rotate_by(angle * Math::PI / 180.0)
  end
  
  def rotate_by_degrees!(angle)
    self[0], self[1] = rotate_by_degrees(angle)
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
  
  def times(scalar)
    map { |value| value * scalar }
  end
  
  def angle
    Math::atan2 at(1), at(0)
  end

  def norm
    Math::sqrt(dot self)
  end
  
  def normalised
    times(1.0 / norm)
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
  
  def many?
    length > 1
  end
  
  def segments
    self[0..-2].zip self[1..-1]
  end
  
  def ring
    zip rotate
  end
  
  def to_path_data(*close)
    self.inject do |memo, point|
      [ *memo, ?L, *point ]
    end.unshift(?M).push(*close).join(?\s)
  end
end

class String
  def in_two
    words = split ?\s
    (1...words.length).map do |index|
      [ words[0 ... index].join(?\s), words[index ... words.length].join(?\s) ]
    end.min_by do |lines|
      lines.map(&:length).max
    end || [ dup ]
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
        point_or_points.each_slice(500).map do |points|
          echoes = points.map { |point| "echo #{point.join ?\s}" }.join " && "
          %x[(#{echoes}) | gdaltransform -s_srs "#{self}" -t_srs "#{target}"].each_line.map do |line|
            line.split(?\s)[0..1].map(&:to_f)
          end
        end.inject(&:+)
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
            point.rotate_by_degrees(-rotation)
          end.transpose.map do |coords|
            [ coords.max, coords.min ]
          end.map do |max, min|
            [ 0.5 * (max + min), max - min ]
          end.transpose
          @centre.rotate_by_degrees!(rotation)
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
    
    def corners(margin = 0)
      @extents.map do |extent|
        [ -0.5 * extent - margin, 0.5 * extent + margin ]
      end.inject(&:product).values_at(1,3,2,0).map do |point|
        @centre.plus point.rotate_by_degrees(@rotation)
      end
    end
    
    def wgs84_corners(margin = 0)
      @projection.reproject_to_wgs84 corners(margin)
    end
    
    def edges(margin)
      axes = [ 180, 90, 0, -90 ].map do |angle|
        [ 1, 0 ].rotate_by_degrees(@rotation + angle)
      end
      [ axes, corners(margin) ].transpose
    end
    
    def coords_to_mm(coords)
      coords.one_or_many do |easting, northing|
        [ easting - bounds.first.first, bounds.last.last - northing ].map do |metres|
          1000.0 * metres / scale
        end
      end
    end
    
    def overlaps?(bounds)
      axes = [ [ 1, 0 ], [ 0, 1 ] ].map { |axis| axis.rotate_by_degrees(@rotation) }
      bounds.inject(&:product).map do |corner|
        axes.map { |axis| corner.minus(@centre).dot(axis) }
      end.transpose.zip(@extents).none? do |projections, extent|
        projections.max < -0.5 * extent || projections.min > 0.5 * extent
      end
    end
    
    def write_world_file(path, resolution)
      topleft = [ @centre, @extents.rotate_by_degrees(-@rotation), [ :-, :+ ] ].transpose.map { |coord, extent, plus_minus| coord.send(plus_minus, 0.5 * extent) }
      WorldFile.write topleft, resolution, @rotation, path
    end
    
    def write_oziexplorer_map(path, name, image, ppi)
      dimensions = dimensions_at(ppi)
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
          svg.add_element("defs")
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
  
  class Source
    def initialize(layer_name, params)
      @layer_name = layer_name
      @params = params
    end
    attr_reader :layer_name, :params, :path
    
    def exist?
      path.nil? || path.exist?
    end
    
    def rerender(xml, map)
      scale_by = lambda do |factor, string|
        string.split(/[,\s]+/).map { |number| factor * number.to_f }.join(?\s)
      end
      xml.elements.each("/svg/g[@id='#{layer_name}' or starts-with(@id,'#{layer_name}#{SEGMENT}')][*]") do |layer|
        layer_id = layer.attributes["id"]
        sublayer_name = layer_id.split(/^#{layer_name}#{SEGMENT}?/).last
        puts "... #{sublayer_name}" unless layer_id == layer_name
        (params["equivalences"] || {}).select do |group, sublayer_names|
          sublayer_names.include? sublayer_name
        end.map(&:first).push(sublayer_name).inject(params) do |memo, key|
          params[key] ? memo.deep_merge(params[key]) : memo
        end.inject({}) do |memo, (command, args)|
          memo.deep_merge case command
          when "colour"   then { "stroke" => args, "fill" => args }
          when "expand"   then { "widen" => args, "stretch" => args }
          when "symbol"   then { "symbols" => { "" => args } }
          when "pattern"  then { "patterns" => { "" => args } }
          when "dupe"     then { "dupes" => { "" => args } }
          when "style"    then { "styles" => { "" => args } }
          when "sample"   then { "samples" => { "" => args } }
          when "endpoint" then { "endpoints" => { "" => args } }
          else { command => args }
          end
        end.tap do |commands|
          commands.merge! "glow" => commands.delete("glow") if commands["glow"]
        end.inject([]) do |memo, (command, args)|
          case command
          when %r{^\./}   then memo << [ command, args ]
          when "opacity" then memo << [ "self::/@style", "opacity:#{args}" ]
          when "width"   then memo << [ ".//[@stroke-width and not(self::text)]/@stroke-width", args ]
          when "glow"
            memo << [ "./*", lambda do |element|
              element.deep_clone.tap do |copy|
                copy.elements.each("descendant-or-self::text") do |text|
                  case args
                  when Float then text.add_attributes "fill" => "none", "stroke" => "white", "stroke-opacity" => 0.75, "stroke-width" => "#{args}em"
                  else            text.add_attributes "fill" => "none", "stroke" => "white", "stroke-opacity" => 0.75, "stroke-width" => "0.1em"
                  end
                end
                element.parent.insert_before element, copy
                element.elements.each(".//font", &:remove)
              end if args
            end ]
          when "stroke", "fill"
            case args
            when Hash
              args.each do |colour, replacement|
                memo << [ ".//[@#{command}='#{colour}']/@#{command}", replacement ]
              end
            else
              memo << [ ".//[@#{command}!='none']/@#{command}", args ]
            end
          when "widen", "stretch", "expand-glyph"
            case command
            when "widen"        then %w[stroke-width stroke-miterlimit]
            when "stretch"      then %w[stroke-dasharray]
            when "expand-glyph" then %w[font-size]
            end.each { |name| memo << [ ".//[@#{name}]/@#{name}", scale_by.curry[args] ] }
          when "dash"
            case args
            when nil             then memo << [ ".//[@stroke-dasharray]/@stroke-dasharray", nil ]
            when String, Numeric then memo << [ ".//(path|polyline)", { "stroke-dasharray" => args } ]
            end
          when "order"
            args.reverse.map do |categories|
              "./[starts-with(@class,'#{categories}')]"
            end.each do |xpath|
              layer.elements.collect(xpath, &:remove).reverse.each do |element|
                layer.unshift element
              end
            end
          when "symbols"
            args.each do |categories, elements|
              [ *categories ].select do |category|
                layer.elements[".//[@class][starts-with(@class,'#{category}')]"]
              end.each do |category|
                id = [ layer_id, *category.split(?\s), "symbol" ].join SEGMENT
                memo << [ "//svg/defs", { "g" => { "id" => id } } ]
                memo << [ "//svg/defs/g[@id='#{id}']", elements ]
                memo << [ ".//[@class][starts-with(@class,'#{category}')]/use", { "xlink:href" => "##{id}"} ]
              end
            end
          when "patterns"
            args.each do |categories, elements|
              [ *categories ].select do |category|
                layer.elements[".//[@class][starts-with(@class,'#{category}')]"]
              end.each do |category|
                id = [ layer_id, *category.split(?\s), "pattern" ].join SEGMENT
                memo << [ "//svg/defs", { "pattern" => { "id" => id, "patternUnits" => "userSpaceOnUse", "patternTransform" => "rotate(#{-map.rotation})" } } ]
                memo << [ "//svg/defs/pattern[@id='#{id}']", elements ]
                memo << [ ".//[@class][starts-with(@class,'#{category}')]", { "fill" => "url(##{id})"} ]
              end
            end
          when "dupes"
            args.each do |categories, names|
              [ *categories ].each do |category|
                layer.elements.each(".//[@class][starts-with(@class,'#{category}')]") do |group|
                  classes = group.attributes["class"].to_s.split(?\s)
                  id = [ layer_id, *classes, "original" ].join SEGMENT
                  elements = group.elements.map(&:remove)
                  [ *names ].each do |name|
                    group.add_element "use", "xlink:href" => "##{id}", "class" => [ name, *classes ].join(?\s)
                  end
                  original = group.add_element("g", "id" => id)
                  elements.each do |element|
                    original.elements << element
                  end
                end
              end
            end
          when "styles"
            args.each do |categories, attributes|
              [ *categories ].each do |category|
                memo << [ ".//[@class][contains(@class,'#{category}')]", attributes ]
              end
            end
          when "samples"
            args.each do |categories, attributes|
              [ *categories ].select do |category|
                layer.elements[".//g[@class][starts-with(@class,'#{category}')]/path"]
              end.each do |category|
                elements = case attributes
                when Array then attributes.map(&:to_a).inject(&:+) || []
                when Hash  then attributes.map(&:to_a)
                end.map { |key, value| { key => value } }
                interval = elements.find { |hash| hash["interval"] }.delete("interval")
                elements.reject!(&:empty?)
                ids = elements.map.with_index do |element, index|
                  [ layer_id, *category.split(?\s), "symbol", *(index if elements.many?) ].join(SEGMENT).tap do |id|
                    memo << [ "//svg/defs", { "g" => { "id" => id } } ]
                    memo << [ "//svg/defs/g[@id='#{id}']", element ]
                  end
                end
                layer.elements.each(".//g[@class][starts-with(@class,'#{category}')]/path") do |path|
                  uses = []
                  path.attributes["d"].to_s.gsub(/\s*Z\s*/i, '').split(/\s*M\s*/i).reject(&:empty?).each do |subpath|
                    subpath.split(/\s*L\s*/i).map do |pair|
                      pair.split(/\s+/).map(&:to_f)
                    end.segments.inject(0.5) do |alpha, segment|
                      angle = 180.0 * segment[1].minus(segment[0]).angle / Math::PI
                      while segment.inject(&:minus).norm > alpha * interval
                        fraction = alpha * interval / segment.inject(&:minus).norm
                        segment[0] = segment[1].times(fraction).plus segment[0].times(1.0 - fraction)
                        uses << { "use" => {"transform" => "translate(#{segment[0].join ?\s}) rotate(#{angle})", "xlink:href" => "##{ids.sample}" } }
                        alpha = 1.0
                      end
                      alpha - segment.inject(&:minus).norm / interval
                    end
                  end
                  memo << [ ".//g[@class][starts-with(@class,'#{category}')]", uses ]
                end
              end
            end
          when "endpoints"
            args.each do |categories, attributes|
              [ *categories ].select do |category|
                layer.elements[".//g[@class][starts-with(@class,'#{category}')]/path"]
              end.each do |category|
                id = [ layer_id, *category.split(?\s), "endpoint" ].join SEGMENT
                memo << [ "//svg/defs", { "g" => { "id" => id } } ]
                memo << [ "//svg/defs/g[@id='#{id}']", attributes ]
                layer.elements.each(".//g[@class][starts-with(@class,'#{category}')]/path") do |path|
                  uses = []
                  path.attributes["d"].to_s.gsub(/\s*Z\s*/i, '').split(/\s*M\s*/i).reject(&:empty?).each do |subpath|
                    subpath.split(/\s*L\s*/i).values_at(0,1,-2,-1).map do |pair|
                      pair.split(/\s+/).map(&:to_f)
                    end.segments.values_at(0,-1).zip([ :to_a, :reverse ]).map do |segment, order|
                      segment.send order
                    end.each do |segment|
                      angle = 180.0 * segment[1].minus(segment[0]).angle / Math::PI
                      uses << { "use" => { "transform" => "translate(#{segment.first.join ?\s}) rotate(#{angle})", "xlink:href" => "##{id}" } }
                    end
                  end
                  memo << [ ".//g[@class][starts-with(@class,'#{category}')]", uses ]
                end
              end
            end
          end
          memo
        end.each.with_index do |(xpath, args), index|
          case args
          when nil
            REXML.each(layer, xpath, &:remove)
          when Hash, Array
            REXML::XPath.each(layer, xpath) do |node|
              case node
              when REXML::Element
                case args
                when Array then args.map(&:to_a).inject(&:+) || []
                when Hash  then args
                end.each do |key, value|
                  case value
                  when Hash then node.add_element key, value
                  else           node.add_attribute key, value
                  end
                end
              end
            end
          when Proc
            # TODO: needed for "glow" command; remove later
            REXML::XPath.each(layer, xpath) do |node|
              case node
              when REXML::Attribute then node.element.attributes[node.name] = args.(node.value)
              when REXML::Element   then args.(node)
              end
            end
          else
            REXML::XPath.each(layer, xpath) do |node|
              case node
              when REXML::Attribute then node.element.attributes[node.name] = args
              when REXML::Element   then [ *args ].each { |tag| node.add_element tag }
              when REXML::Text      then node.value = args
              end
            end
          end
        end
        until layer.elements.each(".//g[not(*)]", &:remove).empty? do
        end
      end
    end
  end
  
  module Annotation
    def svg_coords(coords, projection, map)
      # map.coords_to_mm projection.reproject_to(map.projection, coords) # TODO: make this conversion?
      projection.reproject_to(map.projection, coords).one_or_many do |easting, northing|
        [ easting - map.bounds.first.first, map.bounds.last.last - northing ].map do |metres|
          1000.0 * metres / map.scale
        end
      end
    end
    
    def render_svg(xml, map, &block)
      xml.elements.each("/svg/defs/[starts-with(@id,'#{layer_name}#{SEGMENT}')]", &:remove)
      layers = Hash.new do |layers, id|
        layers[id] = REXML::Element.new("g").tap do |layer|
          layer.add_attributes "id" => id, "style" => "opacity:1", "transform" => map.svg_transform(1)
          xml.elements["/svg/g[@id='#{id}']"].tap do |old_layer|
            old_layer ? old_layer.replace_with(layer) : yield(layer)
          end
        end
      end
      draw(map) do |sublayer_name|
        id = [ layer_name, sublayer_name ].compact.join(SEGMENT)
        layers[id]
      end
    end
  end
  
  module RasterRenderer
    def initialize(*args)
      super(*args)
      ext = params["ext"] || "png"
      @path = Pathname.pwd + "#{layer_name}.#{ext}"
    end
    
    def resolution_for(map)
      params["resolution"] || map.scale / 12500.0
    end
    
    def create(map)
      resolution = resolution_for map
      dimensions = map.extents.map { |extent| (extent / resolution).ceil }
      pixels = dimensions.inject(:*) > 500000 ? " (%.1fMpx)" % (0.000001 * dimensions.inject(:*)) : nil
      puts "Creating: %s, %ix%i%s @ %.1f m/px" % [ layer_name, *dimensions, pixels, resolution]
      Dir.mktmppath do |temp_dir|
        FileUtils.cp get_raster(map, dimensions, resolution, temp_dir), path
      end
    end
    
    def clip_paths(layer)
      [ *params["clips"] ].map do |sublayer|
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
          clippath.add_attribute("id", [ layer_name, "clip", index ].join(SEGMENT))
          clippath.add_element("path", attributes)
        end
      end
    end
    
    def render_svg(xml, map, &block)
      resolution = resolution_for map
      transform = "scale(#{1000.0 * resolution / map.scale})"
      opacity = params["opacity"] || 1
      dimensions = map.extents.map { |extent| (extent / resolution).ceil }
      
      href = if respond_to?(:embed_image) && params["embed"] != false
        Dir.mktmppath do |temp_dir|
          raster_path = embed_image(temp_dir)
          base64 = Base64.encode64 raster_path.read(:mode => "rb")
          mimetype = %x[identify -quiet -verbose "#{raster_path}"][/image\/\w+/] || "image/png"
          "data:#{mimetype};base64,#{base64}"
        end
      else
        raise BadLayerError.new("#{layer_name} raster image not found at #{path}") unless path.exist?
        path.basename
      end
      
      layer = REXML::Element.new("g")
      xml.elements["/svg/g[@id='#{layer_name}']"].tap do |old_layer|
        old_layer ? old_layer.replace_with(layer) : yield(layer)
      end
      layer.add_attributes "id" => layer_name, "style" => "opacity:#{opacity}"
      xml.elements["/svg/defs"].tap do |defs|
        defs.elements.each("clipPath[starts-with(@id, '#{layer_name}#{SEGMENT}clip')]", &:remove)
        clip_paths(layer).each do |clippath|
          defs.elements << clippath
        end
      end.elements.collect("clipPath[starts-with(@id, '#{layer_name}#{SEGMENT}clip')]") do |clippath|
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
    end
  end
  
  class TiledServer < Source
    include RasterRenderer
    
    def get_raster(map, dimensions, resolution, temp_dir)
      tile_paths = tiles(map, resolution, temp_dir).map do |tile_bounds, tile_resolution, tile_path|
        topleft = [ tile_bounds.first.min, tile_bounds.last.max ]
        WorldFile.write topleft, tile_resolution, 0, Pathname.new("#{tile_path}w")
        %Q["#{tile_path}"]
      end
      
      tif_path = temp_dir + "#{layer_name}.tif"
      tfw_path = temp_dir + "#{layer_name}.tfw"
      vrt_path = temp_dir + "#{layer_name}.vrt"
      
      density = 0.01 * map.scale / resolution
      %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:black -type TrueColor -depth 8 "#{tif_path}"]
      unless tile_paths.empty?
        %x[gdalbuildvrt "#{vrt_path}" #{tile_paths.join ?\s}]
        map.write_world_file tfw_path, resolution
        resample = params["resample"] || "cubic"
        projection = Projection.new(params["projection"])
        %x[gdalwarp -s_srs "#{projection}" -t_srs "#{map.projection}" -r #{resample} "#{vrt_path}" "#{tif_path}"]
      end
      
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert -quiet "#{tif_path}" "#{raster_path}"]
      end
    end
  end
  
  class TiledMapServer < TiledServer
    def tiles(map, raster_resolution, temp_dir)
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
      
      format, name = params.values_at("format", "name")
      
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
    def tiles(map, raster_resolution, temp_dir)
      projection = Projection.new(params["projection"])
      bounds = map.transform_bounds_to(projection)
      images_regions = case
      when params["image"]
        { params["image"] => params["region"] }
      when params["config"]
        HTTP.get(URI::HTTP.build(:host => params["host"], :path => params["config"])) do |response|
          vars, images = response.body.scan(/(.+)_ECWP_URL\s*?=\s*?.*"(.+)";/x).transpose
          regions = vars.map do |var|
            response.body.match(/#{var}_CLIP_REGION\s*?=\s*?\[(.+)\]/x) do |match|
              match[1].scan(/\[(.+?),(.+?)\]/x).map { |coords| coords.map(&:to_f) }
            end
          end
          [ images, regions ].transpose.map { |image, region| { image => region } }.inject({}, &:merge)
        end
      end
    
      otdf = params["otdf"]
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
  
  module ArcGIS
    UNDERSCORES = /[\s\(\)]/
    
    def self.included(base)
      attr_reader :service, :headers
    end
    
    def export_uri(query)
      service_type, function = params["image"] ? %w[ImageServer exportImage] : %w[MapServer export]
      uri_path = [ "", params["instance"] || "arcgis", "rest", "services", params["folder"], params["service"], service_type, function ].compact.join ?/
      URI::HTTP.build :host => params["host"], :path => uri_path, :query => URI.escape(query.to_query)
    end
    
    def service_uri(query)
      service_type = params["image"] ? "ImageServer" : "MapServer"
      uri_path = [ "", params["instance"] || "arcgis", "rest", "services", params["folder"], params["service"], service_type ].compact.join ?/
      URI::HTTP.build :host => params["host"], :path => uri_path, :query => URI.escape(query.to_query)
    end
    
    def get_service
      if params["cookie"]
        cookie = HTTP.head(URI.parse params["cookie"]) { |response| response["Set-Cookie"] }
        @headers = { "Cookie" => cookie }
      end
      @service = HTTP.get(service_uri("f" => "json"), headers) do |response|
        JSON.parse(response.body).tap do |result|
          raise Net::HTTPBadResponse.new(result["error"]["message"]) if result["error"]
        end
      end
      service["layers"].each { |layer| layer["name"] = layer["name"].gsub(UNDERSCORES, ?_) } if service["layers"]
      service["mapName"] = service["mapName"].gsub(UNDERSCORES, ?_) if service["mapName"]
    end
  end
  
  module ArcGISTiled
    def initialize(*args)
      super(*args)
      params["tile_sizes"] ||= [ 2048, 2048 ]
      params["interval"] ||= 0.1
    end
    
    def get_tile(bounds, sizes, options)
      # TODO: we could tidy this up a bit...
      srs = { "wkt" => options["wkt"] }.to_json
      query = {
        "bbox" => bounds.transpose.flatten.join(?,),
        "bboxSR" => srs,
        "imageSR" => srs,
        "size" => sizes.join(?,),
        "f" => "image"
      }
      if params["image"]
        query["format"] = "png24",
        query["interpolation"] = params["interpolation"] || "RSP_BilinearInterpolation"
      else
        %w[layers layerDefs dpi format dynamicLayers].each do |key|
          query[key] = options[key] if options[key]
        end
        query["transparent"] = true
      end
      
      HTTP.get(export_uri(query), headers) do |response|
        block_given? ? yield(response.body) : response.body
      end
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
  end
  
  class ArcGISRaster < Source
    include ArcGIS
    include ArcGISTiled
    include RasterRenderer
    
    def get_raster(map, dimensions, resolution, temp_dir)
      get_service
      scale = params["scale"] || map.scale
      options = { "dpi" => scale * 0.0254 / resolution, "wkt" => map.projection.wkt_esri, "format" => "png32" }
      
      dataset = tiles(map, resolution).with_progress.with_index.map do |(tile_bounds, tile_sizes, tile_offsets), tile_index|
        sleep params["interval"] if params["interval"]
        tile_path = temp_dir + "tile.#{tile_index}.png"
        tile_path.open("wb") do |file|
          file << get_tile(tile_bounds, tile_sizes, options)
        end
        [ tile_bounds, tile_sizes, tile_offsets, tile_path ]
      end
      
      temp_dir.join(path.basename).tap do |raster_path|
        density = 0.01 * map.scale / resolution
        alpha = params["background"] ? %Q[-background "#{params['background']}" -alpha Remove] : nil
        if map.rotation.zero?
          sequence = dataset.map do |_, tile_sizes, tile_offsets, tile_path|
            %Q[#{OP} "#{tile_path}" +repage -repage +#{tile_offsets[0]}+#{tile_offsets[1]} #{CP}]
          end.join ?\s
          resize = (params["resolution"] || params["scale"]) ? "-resize #{dimensions.join ?x}!" : "" # TODO: check?
          %x[convert #{sequence} -compose Copy -layers mosaic -units PixelsPerCentimeter -density #{density} #{resize} #{alpha} "#{raster_path}"]
        else
          tile_paths = dataset.map do |tile_bounds, _, _, tile_path|
            topleft = [ tile_bounds.first.first, tile_bounds.last.last ]
            WorldFile.write topleft, resolution, 0, Pathname.new("#{tile_path}w")
            %Q["#{tile_path}"]
          end.join ?\s
          vrt_path = temp_dir + "#{layer_name}.vrt"
          tif_path = temp_dir + "#{layer_name}.tif"
          tfw_path = temp_dir + "#{layer_name}.tfw"
          %x[gdalbuildvrt "#{vrt_path}" #{tile_paths}]
          %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type TrueColorMatte -depth 8 "#{tif_path}"]
          map.write_world_file tfw_path, resolution
          %x[gdalwarp -s_srs "#{map.projection}" -t_srs "#{map.projection}" -dstalpha -r cubic "#{vrt_path}" "#{tif_path}"]
          %x[convert "#{tif_path}" -quiet #{alpha} "#{raster_path}"]
        end
      end
    end
  end
  
  class ArcGISVector < Source
    include ArcGIS
    include ArcGISTiled
    DEFAULT_MM_PER_TILE = 200
    
    def initialize(layer_name, params)
      super layer_name, { "labels" => { "glow" => true } }.deep_merge(params)
      @path = Pathname.pwd + "#{layer_name}.svg"
    end
    
    def get_tile_xml(tile_bounds, tile_sizes, options, *uniquifiers)
      tile_data = get_tile(tile_bounds, tile_sizes, options)
      raise BadLayerError.new(JSON.parse(tile_data)["error"]["message"]) if tile_data[0..8] == '{"error":'
      tile_data.gsub! /ESRITransportation\&Civic/, "ESRITransportation&amp;Civic"
      tile_data.gsub! /ESRIEnvironmental\&Icons/,  "ESRIEnvironmental&amp;Icons"
      layer_ids = service["layers"].map { |layer| layer["name"].sub(/^\d/, ?_) }
      [ /id="(\w+)"/, /url\(#(\w+)\)"/, /xlink:href="#(\w+)"/ ].each do |regex|
        tile_data.gsub! regex do |match|
          case $1
          when "Labels", service["mapName"], *layer_ids then match
          else match.sub $1, [ layer_name, *uniquifiers, $1 ].compact.join(SEGMENT)
          end
        end
      end
      REXML::Document.new(tile_data)
    rescue REXML::ParseException => e
      raise ServerError.new("Bad XML data received: #{e.message}")
    end
    
    def create(map)
      puts "Downloading: #{layer_name}"
      get_service
      
      resolution = params["resolution"] || DEFAULT_MM_PER_TILE * 0.001 * map.scale / params["tile_sizes"].min
      tile_list = tiles(map, resolution, 3) # TODO: margin of 3 means what?
      layer_transform = map.svg_transform(1000.0 * resolution / map.scale)
      
      xml = map.xml
      xml.elements["/svg/defs"].tap do |defs|
        tile_list.each do |tile_bounds, tile_sizes, tile_offsets|
          defs.add_element("clipPath", "id" => [ layer_name, "tile", *tile_offsets ].join(SEGMENT)) do |clippath|
            clippath.add_element("rect", "width" => tile_sizes[0], "height" => tile_sizes[1])
          end
        end
      end
      
      layers = Hash.new do |layers, sublayer_name|
        layers[sublayer_name] = REXML::Element.new("g").tap do |layer|
          layer.add_attributes "style" => "opacity:1", "transform" => layer_transform, "id" => [ layer_name, sublayer_name ].compact.join(SEGMENT)
          xml.elements["/svg"].elements << layer
        end
      end
      
      download_layers(map, tile_list, resolution) do |sublayer_name|
        layers[sublayer_name]
      end
      
      xml.elements.collect("//font", &:remove).group_by do |font|
        [ font.elements["font-face"].attributes.keys, font.elements["font-face"].attributes.values.map(&:value) ].transpose
      end.each do |fontface_attributes, fonts|
        xml.elements["/svg/defs"].add_element("font", fonts.first.attributes) do |font|
          font.elements << fonts.first.elements["font-face"].remove
          font.elements << fonts.first.elements["missing-glyph"].remove
          fonts.map do |font|
            font.elements.collect("glyph", &:remove)
          end.flatten.group_by do |glyph|
            glyph.attributes["unicode"]
          end.sort_by(&:first).each do |unicode, glyphs|
            font.elements << glyphs.first
          end
        end
      end
      
      xml.elements.each("//path[@d='']", &:remove)
      until xml.elements.each("/svg/g[@id]//g[not(*)]", &:remove).empty? do
      end
      
      Dir.mktmppath do |temp_dir|
        svg_path = temp_dir + "#{layer_name}.svg"
        File.write svg_path, xml
        FileUtils.cp svg_path, path
      end
    rescue REXML::ParseException => e
      abort "Bad XML received:\n#{e.message}"
    end
    
    def download_layers(map, tile_list, resolution)
      downloads = %w[features text].select do |type|
        params[type]
      end.map do |type|
        case params[type]
        when Hash
          params[type].map do |scale_or_multiplier, layers|
            case scale_or_multiplier
            when Integer then [ scale_or_multiplier, layers]
            when Float then [ scale_or_multiplier * map.scale, layers ]
            when nil then [ map.scale, layers ]
            end
          end
        when String, Array
          { map.scale => [ *params[type] ] }
        when true
          { map.scale => service["layers"].select { |layer| layer["parentLayerId"] == -1 }.map { |layer| layer["name"] } }
        end.map do |scale, layers|
          dpi = scale * 0.0254 / resolution
          if params["integer-dpi"]
            dpi = dpi.floor
            scale = dpi * resolution / 0.0254
          end
          layers.inject([]) do |memo, (key, value)|
            case value
            when Array then memo + value.map { |val| [ key, val ] }
            else memo << [ key, value ]
            end
          end.map do |key, value|
            case value
            when String then [ key, { "name" => value } ]  # key is a sublayer name, value is a service layer name
            when Fixnum then [ key, { "id" => value } ]    # key is a sublayer name, value is a service layer ID
            when Hash   then [ key, value ]                # key is a sublayer name, value is layer options
            when nil
              case key
              when String then [ key, { "name" => key } ]  # key is a service layer name
              when Hash                                    # key is a service layer name with definition
                [ key.first.first, { "name" => key.first.first, "definition" => key.first.last } ]
              when Fixnum                                  # key is a service layer ID
                layer = service["layers"].find { |layer| layer["id"] == key }
                [ layer["name"], { "id" => layer["id"] } ]
              end
            end
          end.each do |sublayer_name, options|
            options["name"] = options["name"].gsub UNDERSCORES, ?_ if options["name"]
            options["id"] ||= service["layers"].find { |layer| layer["name"] == options["name"] }.fetch("id")
            options["names"] = [ ].tap do |layers|
              loop do
                layers << service["layers"].find do |layer|
                  layer["id"] == (layers.empty? ? options["id"] : layers.last["parentLayerId"])
                end
                break unless layers.last
              end
            end.compact.reverse.map do |layer|
              layer["name"].gsub(UNDERSCORES, ?_)
            end
          end.inject([]) do |memo, (sublayer_name, options)|
            memo.find do |group|
              group.none? do |_, other_options|
                other_options["id"] == options["id"]
              end
            end.tap do |group|
              group ||= (memo << []).last
              group << [ sublayer_name, options ]
            end
            memo
          end.map do |group|
            [ scale, dpi, group, type ]
          end
        end
      end.inject(:+).inject(:+)
      
      downloads.map do |_, _, group, type|
        case type
        when "features"
          group.map do |sublayer_name, options|
            order = params["order"] ? -params["order"].index(sublayer_name) : -options["id"]
            [ order, sublayer_name ]
          end
        when "text" then [ [ 1, "labels" ] ]
        end
      end.inject(&:+).sort_by(&:first).map(&:last).each do |sublayer_name|
        yield sublayer_name
      end
      
      layerset = downloads.map do |_, _, group, type|
        case type
        when "features"
          group.map do |sublayer_name, options|
            [ options["names"], yield(sublayer_name) ]
          end
        when "text" then [ [ %w[Labels], yield("labels") ] ]
        end
      end
      
      tile_list.with_progress.map do |tile_bounds, tile_sizes, tile_offsets|
        tile_transform = "translate(#{tile_offsets.join ?\s})"
        tile_clip_path = "url(##{[ layer_name, 'tile', *tile_offsets ].join(SEGMENT)})"
        tileset = downloads.map do |scale, dpi, group, type|
          sleep params["interval"] if params["interval"]
          ids, layer_defs = group.map(&:last).map do |options|
            id, definition = options.values_at("id", "definition")
            layer_def = "#{id}:#{definition}" if definition
            [ id, layer_def ]
          end.transpose
          query_options = { "dpi" => dpi, "wkt" => map.projection.wkt_esri, "format" => "svg" }
          query_options.merge!("layers" => "show:#{ids.join ?,}") if ids && ids.any?
          query_options.merge!("layerDefs" => layer_defs.compact.join(?;)) if layer_defs && layer_defs.compact.any?
          tile_xml = get_tile_xml(tile_bounds, tile_sizes, query_options, type, scale, *tile_offsets)
          [ scale, tile_xml ]
        end
        
        [ tileset, layerset ].transpose.each do |(scale, tile_xml), layers|
          layers.map do |names, layer|
            xpath = names.map do |name|
              "g[@id='#{name.sub(/^\d/, ?_)}']"
            end.join("//").prepend("/svg//")
            layer_xml = tile_xml.elements[xpath]
            layer_xml.parent.attributes["opacity"].tap do |opacity|
              layer.add_attribute("style", "opacity:#{opacity}") if opacity
            end if layer_xml
            layer.add_element("g", "transform" => tile_transform, "clip-path" => tile_clip_path) do |tile|
              layer_xml.elements.each { |element| tile << element }
              case names.last
              when "Labels"
                tile.elements.each(".//pattern | .//path", &:remove)
              else
                %w[stroke-width stroke-miterlimit stroke-dasharray].each do |name|
                  REXML::XPath.each(tile, ".//[@#{name}]/@#{name}") do |node|
                    node.element.attributes[node.name] = node.value.split(/[,\s]+/).map do |number|
                      number.to_f * map.scale / scale
                    end.join(?\s)
                  end
                end if scale != map.scale
              end
            end if layer_xml and !layer_xml.elements.empty?
          end
        end
      end
    end
    
    def render_svg(xml, map, &block)
      raise BadLayerError.new("source file not found at #{path}") unless path.exist?
      source = REXML::Document.new(path.read)
      
      if xml.elements.each("/svg/g[@id='#{layer_name}' or starts-with(@id,'#{layer_name}#{SEGMENT}')]") do |layer|
        id = layer.attributes["id"]
        layer.replace_with source.elements["/svg/g[@id='#{id}']"]
      end.empty?
        source.elements.each("/svg/g[@id='#{layer_name}' or starts-with(@id,'#{layer_name}#{SEGMENT}')]", &block)
        [ *params["exclude"] ].each do |sublayer_name|
          xml.elements.each("/svg/g[@id='#{[ layer_name, sublayer_name ].join SEGMENT}']", &:remove)
        end
      end
      
         xml.elements.each("/svg/defs/[starts-with(@id,'#{layer_name}#{SEGMENT}')]", &:remove)
      source.elements.each("/svg/defs/[starts-with(@id,'#{layer_name}#{SEGMENT}')]") { |element| xml.elements["/svg/defs"].elements << element }
      
      source.elements.collect("/svg/defs/font", &:remove).each do |font|
        face_predicates = font.elements["font-face"].attributes.values.map { |attribute| "@#{attribute.to_string}" }
        font_predicates = font.attributes.values.map { |attribute| "@#{attribute.to_string}" }
        font_predicates << "font-face[#{face_predicates.join(' and ')}]"
        xml.elements["/svg/defs/font[#{font_predicates.join(' and ')}]"].tap do |existing_font|
          font.elements.collect("glyph", &:remove).reject do |glyph|
            unicode = glyph.attributes["unicode"]
            existing_font.elements["glyph[@unicode='#{unicode}']"]
          end.each do |glyph|
            existing_font.elements << glyph
          end if existing_font
          xml.elements["/svg/defs"].elements << font unless existing_font
        end
      end
    end
  end
  
  class ArcGISIdentify < Source
    include Annotation
    FONT_ASPECT = 0.7
    
    def initialize(*args)
      super(*args)
      @path = Pathname.pwd + "#{layer_name}.json"
    end
    
    def create(map)
      puts "Downloading: #{layer_name}"
      
      %w[host instance folder service cookie].map do |key|
        { key => params.delete(key) }
      end.inject(&:merge).tap do |default|
        params["sources"] = { "default" => default }
      end unless params["sources"]
      
      sources = params["sources"].map do |name, source|
        if source["cookie"]
          cookie = HTTP.head(URI.parse source["cookie"]) { |response| response["Set-Cookie"] }
          source["headers"] = { "Cookie" => cookie }
        end
        source["path"] = [ "", source["instance"] || "arcgis", "rest", "services", source["folder"], source["service"], "MapServer" ]
        uri = URI::HTTP.build(:host => source["host"], :path => source["path"].join(?/), :query => "f=json")
        source["service"] = HTTP.get(uri, source["headers"]) do |response|
          JSON.parse(response.body).tap do |result|
            raise Net::HTTPBadResponse.new(result["error"]["message"]) if result["error"]
          end
        end
        { name => source }
      end.inject(&:merge)
      
      params["features"].inject([]) do |memo, (key, value)|
        case value
        when Array then memo + value.map { |val| [ key, val ] }
        else memo << [ key, value ]
        end
      end.map do |key, value|
        case value
        when Fixnum then [ key, { "id" => value } ]    # key is a sublayer name, value is a service layer name
        when String then [ key, { "name" => value } ]  # key is a sublayer name, value is a service layer ID
        when Hash   then [ key, value ]                # key is a sublayer name, value is layer options
        when nil
          case key
          when String then [ key, { "name" => key } ]  # key is a service layer name
          when Hash                                    # key is a service layer name with definition
            [ key.first.first, { "name" => key.first.first, "definition" => key.first.last } ]
          when Fixnum                                  # key is a service layer ID
            [ sources.values.first["service"]["layers"].find { |layer| layer["id"] == key }.fetch("name"), { "id" => key } ]
          end
        end
      end.reject do |sublayer_name, options|
        params["exclude"].include? sublayer_name
      end.map do |sublayer_name, options|
        [ sources[options["source"] || sources.keys.first], sublayer_name, options ]
      end.each do |source, sublayer_name, options|
        options["id"] = source["service"]["layers"].find do |layer|
          layer["name"] == options["name"]
        end.fetch("id") unless options["id"]
        URI::HTTP.build(:host => source["host"], :path => [ *source["path"], options["id"] ].join(?/), :query => "f=json").tap do |uri|
          scales = HTTP.get(uri, source["headers"]) do |response|
            JSON.parse(response.body).tap do |result|
              raise Net::HTTPBadResponse.new(result["error"]["message"]) if result["error"]
            end
          end.values_at("minScale", "maxScale")
          options["scale"] = scales.last.zero? ? scales.first.zero? ? map.scale : 2 * scales.first : scales.inject(&:+) / 2
        end unless options["scale"]
      end.map do |source, sublayer_name, options|
        $stdout << "... #{sublayer_name}"
        pixels = map.wgs84_bounds.map do |bound|
          bound.reverse.inject(&:-) * 96 * 110000 / options["scale"] / 0.0254
        end.map(&:round)
        query = {
          "f" => "json",
          "sr" => 4326,
          "geometryType" => "esriGeometryPolygon",
          "geometry" => { "rings" => [ map.wgs84_corners << map.wgs84_corners.first ] }.to_json,
          "layers" => "all:#{options['id']}",
          "tolerance" => 0,
          "mapExtent" => map.wgs84_bounds.transpose.flatten.join(?,),
          "imageDisplay" => [ *pixels, 96 ].join(?,),
          "returnGeometry" => true,
        }
        results = [ ]
        index_attribute = options["page-by"] || source["page-by"] || "OBJECTID"
        definition, redefine, id = options.values_at("definition", "redefine", "id")
        paginate = nil
        loop do
          definitions = [ *options["definition"], *paginate ]
          paged_query = case
          when definitions.any? && redefine then { "layerDefs" => "#{id}:1 < 0) OR ((#{definitions.join ') AND ('})" }
          when redefine                     then { "layerDefs" => "#{id}:1 < 0) OR (1 > 0" }
          when definitions.any?             then { "layerDefs" => "#{id}:(#{definitions.join ') AND ('})" }
          else                                   { }
          end.merge(query)
          uri = URI::HTTP.build :host => source["host"], :path => [ *source["path"], "identify" ].join(?/), :query => URI.escape(paged_query.to_query)
          body = HTTP.get(uri, source["headers"]) do |response|
            JSON.parse(response.body).tap do |body|
              raise Net::HTTPBadResponse.new(body["error"]["message"]) if body["error"]
            end
          end
          page = body.fetch("results", [ ])
          page.map do |feature|
            raise BadLayerError.new("no attribute available for pagination (try: #{feature['attributes'].keys.join(', ')})") unless feature["attributes"].has_key?(index_attribute)
            feature["attributes"][index_attribute].to_i
          end.max.tap do |value|
            paginate = "#{index_attribute} > #{value}"
          end
          results += page
          $stdout << "\r... #{sublayer_name} (#{results.length} feature#{?s unless results.one?})"
          break unless page.any?
        end
        
        edges = map.edges(0.001 * map.scale)
        features = results.map do |result|
          attributes, geometry_type, geometry = result.values_at "attributes", "geometryType", "geometry"
          wkid = geometry["spatialReference"]["wkid"]
          projection = Projection.new("epsg:#{wkid}")
          data = case geometry_type
          when "esriGeometryPoint"
            projection.reproject_to(map.projection, geometry.values_at("x", "y"))
          when "esriGeometryPolyline"
            geometry["paths"].map do |path|
              projection.reproject_to map.projection, path
            end.map do |path|
              edges.inject([path]) do |subpaths, (axis, offset)|
                subpaths.select(&:many?).map do |subpath|
                  subpath.unshift(subpath[0]).segments.inject([[]]) do |memo, segment|
                    inside = segment.map { |point| point.minus(offset).dot(axis) <= 0 }
                    case
                    when inside[0] && inside[1]
                      memo.last << segment[1]
                    when inside[0]
                      memo.last << (segment[1].times(segment[0].minus(offset).dot axis).minus segment[0].times(segment[1].minus(offset).dot axis)).times(1.0 / segment.inject(&:minus).dot(axis))
                    when inside[1]
                      memo << []
                      memo.last << (segment[1].times(segment[0].minus(offset).dot axis).minus segment[0].times(segment[1].minus(offset).dot axis)).times(1.0 / segment.inject(&:minus).dot(axis))
                      memo.last << segment[1]
                    end
                    memo
                  end.select(&:many?)
                end.flatten(1)
              end
            end.flatten(1).reject(&:empty?)
          when "esriGeometryPolygon"
            geometry["rings"].map do |ring|
              projection.reproject_to map.projection, ring
            end.select(&:many?).map do |ring|
              edges.inject(ring) do |clipped, (axis, offset)|
                clipped.ring.inject([]) do |clipped, segment|
                  inside = segment.map { |point| point.minus(offset).dot(axis) <= 0 }
                  case
                  when inside[0] && inside[1]
                    clipped << segment[1]
                  when inside[0]
                    clipped << (segment[1].times(segment[0].minus(offset).dot axis).minus segment[0].times(segment[1].minus(offset).dot axis)).times(1.0 / segment.inject(&:minus).dot(axis))
                  when inside[1]
                    clipped << (segment[1].times(segment[0].minus(offset).dot axis).minus segment[0].times(segment[1].minus(offset).dot axis)).times(1.0 / segment.inject(&:minus).dot(axis))
                    clipped << segment[1]
                  end
                  clipped
                end
              end
            end.select(&:many?)
          end
          category = [ *options["category"] ].map do |field|
            attributes[field] || field
          end.map do |string|
            string.gsub /\W+/, ?-
          end
          case attributes[options["rotate"]].to_i
          when 0
            category << "no-angle"
          else
            category << "angle"
            angle = 90 - attributes[options["rotate"]].to_i
          end if options["rotate"]
          { "geometryType" => geometry_type, "data" => data, "category" => category }.tap do |feature|
            if options["label"]
              fields = attributes.values_at *options["label"]
              format = options["format"] || (%w[%s] * fields.length).join(?\s)
              unless fields.map(&:to_s).all?(&:empty?)
                feature["label"] = format % fields
                [ *options["label-by"] ].map do |field, field_options|
                  field_options.select do |field_value, opts|
                    [ *field_value ].include? attributes[field]
                  end.map(&:last)
                end.flatten.unshift(options).inject(&:merge).tap do |opts|
                  %w[font-size letter-spacing word-spacing margin orientation position interval].each do |name|
                    feature[name] = opts[name] if opts[name]
                  end
                end
              end
            end
            feature["label-only"] = options["label-only"] if options["label-only"]
          end
        end
        puts
        [ sublayer_name, features ]
      end.inject({}) do |memo, (sublayer_name, features)|
        memo[sublayer_name] ||= []
        memo[sublayer_name] += features
        memo
      end.tap do |layers|
        Dir.mktmppath do |temp_dir|
          json_path = temp_dir + "#{layer_name}.json"
          json_path.open("w") { |file| file << JSON.pretty_generate(layers) }
          # json_path.open("w") { |file| file << layers.to_json }
          FileUtils.cp json_path, path
        end
      end
    end
    
    def solve(labels_conflicts)
      # TODO: currently returning repeated labels, this is BAD!
      # also, very slow, needs optimising
      pending, completed = labels_conflicts.dup, [ ]
      while pending.any?
        pending.min_by do |(index, _), conflicts|
          remaining = pending.select do |other_index, _|
            other_index == index
          end
          [ conflicts.length, remaining.length ]
        end.tap do |label, conflicts|
          conflicts.keys.each do |conflicting_label|
            pending.delete conflicting_label
          end
          pending.delete label
          completed << label
        end
      end
      pending = labels_conflicts.keys.map(&:first).uniq - completed.map(&:first)
      while pending.any?
        pending.each do |index|
          labels_conflicts.select do |(other_index, _), _|
            other_index == index
          end.min_by do |(_, position), conflicts|
            overlaps = conflicts.select do |other_label, _|
              completed.include? other_label
            end.map(&:last)
            [ overlaps.inject(&:+) || 0, position ]
          end.tap do |label, _|
            completed << label
          end
          pending.delete index
        end
      end
      5.times do
        completed.each do |label|
          candidates = labels_conflicts.select do |(other_index, other_position), _|
            other_index == label[0]
          end.map do |(_, other_position), conflicts|
            [ conflicts.values_at(*(completed - [label])).compact.inject(&:+) || 0, other_position ]
          end
          label[1] = candidates.min.last # unless candidates.map(&:first).all?(&:zero?)
        end
      end
      completed
    end
    
    def draw(map)
      raise BadLayerError.new("source file not found at #{path}") unless path.exist?
      names_features = JSON.parse(path.read).reject do |sublayer_name, features|
        params["exclude"].include? sublayer_name
      end.reject do |sublayer_name, features|
        features.empty?
      end
      
      names_features.map do |sublayer_name, features|
        [ sublayer_name, features.reject { |feature| feature["label-only"] } ]
      end.each do |sublayer_name, features|
        puts "... #{sublayer_name}" if features.any?
        features.each do |feature|
          categories = feature["category"].reject(&:empty?).join(?\s)
          geometry_type = feature["geometryType"]
          case geometry_type
          when "esriGeometryPoint"
            x, y = map.coords_to_mm feature["data"]
            angle = feature["angle"]
            transform = "translate(#{x} #{y}) rotate(#{(angle || 0) - map.rotation})"
            yield(sublayer_name).add_element "use", "transform" => transform, "class" => categories
          when "esriGeometryPolyline", "esriGeometryPolygon"
            close, fill_options = case geometry_type
              when "esriGeometryPolyline" then [ nil, { "fill" => "none" }         ]
              when "esriGeometryPolygon"  then [ ?Z,  { "fill-rule" => "evenodd" } ]
            end
            feature["data"].reject(&:empty?).map do |coords|
              map.coords_to_mm coords
            end.map do |points|
              points.to_path_data(*close)
            end.tap do |subpaths|
              yield(sublayer_name).add_element "path", fill_options.merge("d" => subpaths.join(?\s), "class" => categories) if subpaths.any?
            end
          end
        end
      end
      
      puts "... labels"
      point_features, line_features = %w[esriGeometryPoint esriGeometryPolyline].map do |geometry_type|
        names_features.inject([]) do |memo, (sublayer_name, features)|
          memo + features.select do |feature|
            feature.key?("label") && feature["geometryType"] == geometry_type
          end.each do |feature|
            feature["category"].unshift sublayer_name
          end
        end
      end
      
      labels_bounds = point_features.map.with_index do |feature, index|
        lines          = feature["label"].in_two
        font_size      = feature["font-size"]      || 1.5
        letter_spacing = feature["letter-spacing"] || 0
        margin         = feature["margin"]         || 0
        width = lines.map(&:length).max * (font_size * FONT_ASPECT + letter_spacing)
        height = lines.length * font_size
        point = map.coords_to_mm(feature["data"])
        rotated = point.rotate_by_degrees(map.rotation)
        [ *feature["position"] ].map do |position|
          bounds = case position
          when 0 then [ [ -0.5 * width, 0.5 * width ], [ -0.5 * height, 0.5 * height ] ]
          when 1 then [ [ 0, width + margin ], [ -0.5 * height, 0.5 * height ] ]
          when 2 then [ [ -0.5 * width, 0.5 * width ], [ 0, height + margin ] ]
          when 3 then [ [ -0.5 * width, 0.5 * width ], [ -(height + margin), 0 ] ]
          when 4 then [ [ -(width + margin), 0 ], [ -0.5 * height, 0.5 * height ] ]
          end.zip(rotated).map do |offsets, centre|
            offsets.map { |offset| offset + centre }
          end
          { [ index, position ] => bounds }
        end.inject(&:merge) || {}
      end.inject(&:merge) || {}
      
      labels_conflicts = labels_bounds.map do |label, bounds|
        conflicts = labels_bounds.map do |other_label, other_bounds|
          overlaps = bounds.zip(other_bounds).map do |bound, other_bound|
            case
            when other_label == label then nil
            when bound.max < other_bound.min then nil
            when bound.min > other_bound.max then nil
            else [ bound[1], other_bound[1] ].min - [ bound[0], other_bound[0] ].max
            end
          end
          overlaps.all? ? { other_label => overlaps.inject(&:*) } : { }
        end.inject(&:merge) || {}
        { label => conflicts }
      end.inject(&:merge) || {}
      
      solve(labels_conflicts).map do |index, position|
        point_features[index].merge("position" => position)
      end.each do |feature|
        categories     = feature["category"].reject(&:empty?).join(?\s)
        letter_spacing = feature["letter-spacing"]
        font_size      = feature["font-size"] || 1.5
        margin         = feature["margin"]    || 0
        lines = feature["label"].in_two
        point = map.coords_to_mm feature["data"]
        transform = "translate(#{point.join ?\s}) rotate(#{-map.rotation})"
        text_anchor = case feature["position"]
        when 0, 2, 3 then "middle"
        when 1 then "start"
        when 4 then "end"
        end
        yield("labels").add_element("text", "font-size" => font_size, "text-anchor" => text_anchor, "transform" => transform, "class" => categories) do |text|
          text.add_attribute "letter-spacing", letter_spacing if letter_spacing
          lines.each.with_index do |line, index|
            y = (lines.one? ? 0.5 : index) * font_size + case feature["position"]
            when 0, 1, 4 then 0.0
            when 2 then  margin + 0.5 * lines.length * font_size
            when 3 then -margin - 0.5 * lines.length * font_size
            end - 0.15 * font_size
            x = case feature["position"]
            when 0, 2, 3 then 0.0
            when 1 then  margin
            when 4 then -margin
            end
            text.add_element("tspan", "x" => x, "y" => y) do |tspan|
              tspan.add_text line
            end
          end
        end
      end
      
      labels_conflicts = {}
      features_candidates_points = line_features.inject([]) do |features, feature|
        text           = feature["label"]
        font_size      = feature["font-size"]      || 1.5
        letter_spacing = feature["letter-spacing"] || 0
        word_spacing   = feature["word-spacing"]   || 0
        interval       = feature["interval"]       || 150
        length = text.length * (font_size * FONT_ASPECT + letter_spacing) + text.count(?\s) * word_spacing
        feature.delete("data").map do |coords|
          points = map.coords_to_mm coords
          from_start = points.segments.inject([0]) do |memo, segment|
            memo << memo.last + segment.inject(&:minus).norm
          end
          from_centre = from_start.map do |distance|
            (distance - 0.5 * from_start.last).abs
          end
          candidates = from_start.length.times.inject([]) do |memo, finish|
            finish.downto(memo.any? ? memo.last.first + 1 : 0).find do |start|
              from_start[finish] - from_start[start] >= length
            end.tap do |start|
              memo << (start..finish) if start
            end
            memo
          end.reject do |range|
            # TODO: make this smoothness factor a feature property:
            points[range.first].minus(points[range.last]).norm < 0.9 * length
          end.reject do |range|
            points[range].segments.map do |segment|
              segment.inject(&:minus).normalised
            end.segments.any? do |segment|
              # TODO: make this cosine(angle) a feature property:
              segment.inject(&:dot) < 0.707
            end
          # end.reject do |range|
          #   # TODO: reject candidates which cross point-feature labels
          # end.reject do |range|
          #   # TODO: reject candidates adjacent to the ends of the line
          #   from_start[range.first] < 2 || from_start[range.last] > from_start.last - 2
          end.sort_by do |range|
            # TODO: can we sort by path smoothness, maximum turn angle, some other criteria?
            from_centre[range].max
          end
          if candidates.any?
            feature_index = features.length
            candidates.each.with_index do |range1, index1|
              label1 = [ feature_index, index1 ]
              labels_conflicts[label1] = {}
              candidates.each.with_index do |range2, index2|
                label2 = [ feature_index, index2 ]
                case
                # TODO: check proximity between start and end points
                when index1 == index2
                when from_start[range2.first] - from_start[range1.last] > interval
                when from_start[range1.first] - from_start[range2.last] > interval
                else
                  # TODO: instead set a fraction according to closeness of conflicting label
                  # e.g. (interval - separation) / interval
                  labels_conflicts[label1][label2] = 1
                end
              end
            end
            features << [ feature, candidates, points ]
          end
        end
        features
      end
      
      # # TODO: add conflicts between different features!
      # features.each.with_index do |feature1, index1|
      #   features.each.with_index do |feature2, index2|
      #     case
      #     when index1 == index2
      #     else
      #     end
      #   end
      # end
      
      solve(labels_conflicts).uniq.each do |index, position|
        # TODO: uniq should not be needed; solve is returning dupes!
        feature, candidates, points = features_candidates_points[index]
        categories = feature["category"].reject(&:empty?).join(?\s)
        font_size = feature["font-size"] || 1.5
        margin = feature["margin"]
        id = [ layer_name, "labels", "path", index, position ].join SEGMENT
        section = points[candidates[position]]
        left_to_right = section[-1].minus(section[0]).rotate_by_degrees(map.rotation).first > 0
        d = case feature["orientation"]
        when "uphill" then section
        when "downhill" then section.reverse
        else left_to_right ? section : section.reverse
        end.to_path_data
        dy = margin ? margin < 0 ? font_size + margin : -margin : 0.35 * font_size
        yield("labels").elements["//svg/defs"].add_element("path", "id" => id, "d" => d)
        yield("labels").add_element("text", "class" => categories, "font-size" => font_size, "text-anchor" => "middle") do |text|
          text.add_attribute "letter-spacing", feature["letter-spacing"] if feature["letter-spacing"]
          text.add_attribute "word-spacing", feature["word-spacing"] if feature["word-spacing"]
          text.add_element("textPath", "xlink:href" => "##{id}", "startOffset" => "50%") do |text_path|
            text_path.add_element("tspan", "dy" => dy) do |tspan|
              tspan.add_text feature["label"]
            end
          end
        end
      end
      
      names_features.reject do |sublayer_name, features|
        features.all? { |feature| feature["label-only"] }
      end.map(&:first).push("labels").each do |sublayer_name|
        yield(sublayer_name).elements.collect(&:remove).group_by do |element|
          element.attributes["class"]
        end.each do |category, elements|
          yield(sublayer_name).add_element("g", "class" => category) do |group|
            elements.each do |element|
              element.attributes.delete "class"
              group.elements << element
            end
          end
        end
      end
    end
  end
  
  class ArcGISDynamic < ArcGISVector
    def download_layers(map, tile_list, resolution)
      feature_layers = params["layers"].keys.reverse.map do |sublayer_name|
        yield sublayer_name
      end
      label_layer = yield "labels"
      
      start_id = service["layers"].map { |layer| layer["id"] }.max + 1
      dynamic_layers = params["layers"].values.map.with_index do |layer, index|
        layer.merge("id" => start_id + index)
      end
      ids = dynamic_layers.map { |options| options["id"] }
      
      query_options = {
        "dpi" => map.scale * 0.0254 / resolution,
        "wkt" => map.projection.wkt_esri,
        "layers" => "show:#{ids.join ?,}",
        "dynamicLayers" => dynamic_layers.to_json,
        "format" => "svg",
      }
      
      tile_list.with_progress.map do |tile_bounds, tile_sizes, tile_offsets|
        sleep params["interval"] if params["interval"]
        tile_transform = "translate(#{tile_offsets.join ?\s})"
        tile_clip_path = "url(##{[ layer_name, 'tile', *tile_offsets ].join(SEGMENT)})"
        tile_xml = get_tile_xml(tile_bounds, tile_sizes, query_options, *tile_offsets)
        
        layer_xmls = tile_xml.elements.collect("/svg//g[@id]/g[@id]/g[@id!='Labels']") { |layer_xml| layer_xml }
        [ layer_xmls, feature_layers ].transpose.each do |layer_xml, layer|
          layer_xml.parent.attributes["opacity"].tap do |opacity|
            layer.add_attribute("style", "opacity:#{opacity}") if opacity
          end
          layer.add_element("g", "transform" => tile_transform, "clip-path" => tile_clip_path) do |tile|
            layer_xml.elements.each { |element| tile << element }
          end
        end
        tile_xml.elements["/svg//g[@id]/g[@id]/g[@id='Labels']"].tap do |label_xml|
          label_xml.elements.each(".//pattern | .//path", &:remove)
          label_layer.add_element("g", "transform" => tile_transform, "clip-path" => tile_clip_path) do |tile|
            label_xml.deep_clone.tap do |copy|
              copy.elements.each(".//text") { |text| text.add_attributes("stroke" => "white", "opacity" => 0.75) }
            end.elements.each { |element| tile << element }
            label_xml.elements.each { |element| tile << element }
          end
        end
      end
    end
  end
  
  module NoCreate
    def create(map)
      raise BadLayerError.new("#{layer_name} file not found at #{path}")
    end
  end
  
  class ReliefSource < Source
    include RasterRenderer
    
    def initialize(layer_name, params)
      super(layer_name, params.merge("ext" => "tif"))
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      dem_path = if params["path"]
        Pathname.new(params["path"]).expand_path
      else
        base_uri = URI.parse "http://www.ga.gov.au/gisimg/rest/services/topography/dem_s_1s/ImageServer/"
        base_query = { "f" => "json", "geometry" => map.wgs84_bounds.map(&:sort).transpose.flatten.plus([ -0.001, -0.001, 0.001, 0.001 ]).join(?,) }
        query = URI.escape base_query.merge("returnIdsOnly" => true, "where" => "category = 1").to_query
        raster_ids = HTTP.get(base_uri + "query?#{query}") do |response|
          JSON.parse(response.body).tap do |result|
            raise Net::HTTPBadResponse.new(result["error"]["message"]) if result["error"]
          end.fetch("objectIds")
        end
        query = URI.escape base_query.merge("rasterIDs" => raster_ids.join(?,), "format" => "TIFF").to_query
        tile_paths = HTTP.get(base_uri + "download?#{query}") do |response|
          JSON.parse(response.body).tap do |result|
            raise Net::HTTPBadResponse.new(result["error"]["message"]) if result["error"]
          end.fetch("rasterFiles")
        end.map do |file|
          file["id"][/[^@]*/]
        end.select do |url|
          url[/\.tif$/]
        end.map do |url|
          [ URI.parse(URI.escape url), temp_dir + url[/[^\/]*$/] ]
        end.map do |uri, tile_path|
          HTTP.get(uri) do |response|
            tile_path.open("wb") { |file| file << response.body }
          end
          %Q["#{tile_path}"]
        end
    
        temp_dir.join("dem.vrt").tap do |vrt_path|
          %x[gdalbuildvrt "#{vrt_path}" #{tile_paths.join ?\s}]
        end
      end
      raise BadLayerError.new("elevation data not found at #{dem_path}") unless dem_path.exist?
      
      temp_dir.join(path.basename).tap do |tif_path|
        relief_path = temp_dir + "#{layer_name}-uncropped.tif"
        tfw_path = temp_dir + "#{layer_name}.tfw"
        map.write_world_file tfw_path, resolution
        density = 0.01 * map.scale / resolution
        altitude, azimuth, exaggeration = params.values_at("altitude", "azimuth", "exaggeration")
        %x[gdaldem hillshade -compute_edges -s 111120 -alt #{altitude} -z #{exaggeration} -az #{azimuth} "#{dem_path}" "#{relief_path}" -q]
        raise BadLayerError.new("invalid elevation data") unless $?.success?
        %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type GrayscaleMatte -depth 8 "#{tif_path}"]
        %x[gdalwarp -s_srs "#{Projection.wgs84}" -t_srs "#{map.projection}" -r bilinear -srcnodata 0 -dstalpha "#{relief_path}" "#{tif_path}"]
        filters = []
        (params["median"].to_f / resolution).round.tap do |pixels|
          filters << "-statistic median #{2 * pixels + 1}" if pixels > 0
        end
        params["bilateral"].to_f.round.tap do |threshold|
          sigma = (500.0 / resolution).round
          filters << "-selective-blur 0x#{sigma}+#{threshold}%" if threshold > 0
        end
        %x[mogrify -quiet -virtual-pixel edge #{filters.join ?\s} "#{tif_path}"] if filters.any?
      end
    end
    
    def embed_image(temp_dir)
      raise BadLayerError.new("hillshade image not found at #{path}") unless path.exist?
      highlights = params["highlights"]
      shade = %Q["#{path}" -colorspace Gray -fill white -opaque none -level 0,65% -negate -alpha Copy -fill black +opaque black]
      sun = %Q["#{path}" -colorspace Gray -fill black -opaque none -level 80%,100% +level 0,#{highlights}% -alpha Copy -fill yellow +opaque yellow]
      temp_dir.join("overlay.png").tap do |overlay_path|
        %x[convert -quiet #{OP} #{shade} #{CP} #{OP} #{sun} #{CP} -composite "#{overlay_path}"]
      end
    end
  end
  
  class VegetationSource < Source
    include RasterRenderer
    
    def get_raster(map, dimensions, resolution, temp_dir)
      source_paths = [ *params["path"] ].tap do |paths|
        raise BadLayerError.new("no vegetation data file specified") if paths.empty?
      end.map do |source_path|
        Pathname.new(source_path).expand_path
      end.map do |source_path|
        raise BadLayerError.new("vegetation data file not found at #{source_path}") unless source_path.file?
        %Q["#{source_path}"]
      end.join ?\s
      
      vrt_path = temp_dir + "#{layer_name}.vrt"
      tif_path = temp_dir + "#{layer_name}.tif"
      tfw_path = temp_dir + "#{layer_name}.tfw"
      clut_path = temp_dir + "#{layer_name}-clut.png"
      mask_path = temp_dir + "#{layer_name}-mask.png"
      
      %x[gdalbuildvrt "#{vrt_path}" #{source_paths}]
      map.write_world_file tfw_path, resolution
      %x[convert -size #{dimensions.join ?x} canvas:white -type Grayscale -depth 8 "#{tif_path}"]
      %x[gdalwarp -t_srs "#{map.projection}" "#{vrt_path}" "#{tif_path}"]
      
      low, high = { "low" => 0, "high" => 100 }.merge(params["contrast"] || {}).values_at("low", "high")
      fx = params["mapping"].inject(0.0) do |memo, (key, value)|
        "j==#{key} ? %.5f : (#{memo})" % (value < low ? 0.0 : value > high ? 1.0 : (value - low).to_f / (high - low))
      end
      
      %x[convert -size 1x256 canvas:black -fx "#{fx}" "#{clut_path}"]
      %x[convert "#{tif_path}" "#{clut_path}" -clut "#{mask_path}"]
      
      woody, nonwoody = params["colour"].values_at("woody", "non-woody")
      density = 0.01 * map.scale / resolution
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:"#{nonwoody}" #{OP} "#{mask_path}" -background "#{woody}" -alpha Shape #{CP} -composite "#{raster_path}"]
      end
    end
    
    def embed_image(temp_dir)
      raise BadLayerError.new("vegetation raster image not found at #{path}") unless path.exist?
      path
    end
  end
  
  class CanvasSource < Source
    include RasterRenderer
    include NoCreate
    
    def resolution_for(map)
      return params["resolution"] if params["resolution"]
      raise BadLayerError.new("canvas image not found at #{path}") unless path.exist?
      pixels_per_centimeter = %x[convert "#{path}" -units PixelsPerCentimeter -format "%[resolution.x]" info:]
      raise BadLayerError.new("bad canvas image at #{path}") unless $?.success?
      map.scale * 0.01 / pixels_per_centimeter.to_f
    end
  end
  
  class ImportSource < Source
    include RasterRenderer
    
    def resolution_for(map)
      import_path = Pathname.new(params["path"]).expand_path
      Math::sqrt(0.5) * [ [ 0, 0 ], [ 1, 1 ] ].map do |point|
        %x[echo #{point.join ?\s} | gdaltransform "#{import_path}" -t_srs "#{map.projection}"].tap do |output|
          raise BadLayerError.new("couldn't use georeferenced file at #{import_path}") unless $?.success?
        end.split(?\s)[0..1].map(&:to_f)
      end.inject(&:minus).norm
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      import_path = Pathname.new(params["path"]).expand_path
      source_path = temp_dir + "source.tif"
      tfw_path = temp_dir + "#{layer_name}.tfw"
      tif_path = temp_dir + "#{layer_name}.tif"
      
      density = 0.01 * map.scale / resolution
      map.write_world_file tfw_path, resolution
      %x[convert -size #{dimensions.join ?x} canvas:none -type TrueColorMatte -depth 8 -units PixelsPerCentimeter -density #{density} "#{tif_path}"]
      %x[gdal_translate -expand rgba #{import_path} #{source_path}]
      %x[gdal_translate #{import_path} #{source_path}] unless $?.success?
      raise BadLayerError.new("couldn't use georeferenced file at #{import_path}") unless $?.success?
      %x[gdalwarp -t_srs "#{map.projection}" -r bilinear #{source_path} #{tif_path}]
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert "#{tif_path}" -quiet "#{raster_path}"]
      end
    end
  end
  
  class DeclinationSource < Source
    include Annotation
    include NoCreate
    
    def draw(map)
      centre = map.wgs84_bounds.map { |bound| 0.5 * bound.inject(:+) }
      projection = Projection.transverse_mercator(centre.first, 1.0)
      spacing = params["spacing"] / Math::cos(map.declination * Math::PI / 180.0)
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
        svg_coords(line, projection, map)
      end.map(&:to_path_data).each do |d|
        yield.add_element("path", "d" => d, "stroke" => "black", "stroke-width" => "0.1")
      end
    end
  end
  
  class GridSource < Source
    include Annotation
    include NoCreate
    
    def self.zone(coords, projection)
      projection.reproject_to_wgs84(coords).one_or_many do |longitude, latitude|
        (longitude / 6).floor + 31
      end
    end
    
    def draw(map)
      interval = params["interval"]
      label_spacing = params["label-spacing"]
      label_interval = label_spacing * interval
      fontfamily = params["family"]
      fontsize = 25.4 * params["fontsize"] / 72.0
      
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
            d = svg_coords(line, projection, map).to_path_data
            yield("lines").add_element("path", "d" => d, "stroke-width" => "0.1", "stroke" => "black")
            if line[0] && line[0][index] % label_interval == 0 
              coord = line[0][index]
              label_segments = [ [ "%d", (coord / 100000), 80 ], [ "%02d", (coord / 1000) % 100, 100 ] ]
              label_segments << [ "%03d", coord % 1000, 80 ] unless label_interval % 1000 == 0
              label_segments.map! { |template, number, percent| [ template % number, percent ] }
              line.inject do |*segment|
                if segment[0][1-index] % label_interval == 0
                  points = segment.map { |coords| svg_coords(coords, projection, map) }
                  middle = points.transpose.map { |values| 0.5 * values.inject(:+) }
                  angle = 180.0 * Math::atan2(*points[1].minus(points[0]).reverse) / Math::PI
                  transform = "translate(#{middle.join ?\s}) rotate(#{angle})"
                  yield("labels").add_element("text", "transform" => transform, "dy" => 0.25 * fontsize, "font-family" => fontfamily, "font-size" => fontsize, "fill" => "black", "stroke" => "none", "text-anchor" => "middle") do |text|
                    label_segments.each do |digits, percent|
                      text.add_element("tspan", "font-size" => "#{percent}%") do |tspan|
                        tspan.add_text(digits)
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
  
  module PathInParams
    def initialize(*args)
      super(*args)
      @path = Pathname.new(params["path"]).expand_path
    end
  end
  
  class ControlSource < Source
    include Annotation
    include NoCreate
    include PathInParams
    
    def draw(map)
      gps = GPS.new(path)
      radius = 0.5 * params["diameter"]
      strokewidth, fontfamily, spotdiameter = params.values_at "thickness", "family", "spot-diameter"
      fontsize = 25.4 * params["fontsize"] / 72.0
      
      [ [ /\d{2,3}/, :circle,   "circles" ],
        [ /HH/,      :triangle, "circles" ],
        [ /ANC/,     :square,   "circles" ],
        [ /W/,       :water,    "water"   ],
      ].each do |selector, type, sublayer|
        gps.waypoints.map do |waypoint, name|
          [ svg_coords(waypoint, Projection.wgs84, map), name[selector] ]
        end.select(&:last).each do |point, label|
          transform = "translate(#{point.join ?\s}) rotate(#{-map.rotation})"
          yield(sublayer).add_element("g", "transform" => transform) do |rotated|
            case type
            when :circle
              rotated.add_element("circle", "r" => radius, "fill" => "none", "stroke" => "black", "stroke-width" => 0.2)
              rotated.add_element("circle", "r" => 0.5 * spotdiameter, "fill" => "black", "stroke" => "none") if spotdiameter
            when :triangle, :square
              angles = type == :triangle ? [ -90, -210, -330 ] : [ -45, -135, -225, -315 ]
              points = angles.map do |angle|
                [ radius, 0 ].rotate_by_degrees(angle)
              end.map { |vertex| vertex.join ?, }.join ?\s
              rotated.add_element("polygon", "points" => points, "fill" => "none", "stroke" => "black", "stroke-width" => 0.2)
            when :water
              [
                "m -0.79942321,0.07985921 -0.005008,0.40814711 0.41816285,0.0425684 0,-0.47826034 -0.41315487,0.02754198 z",
                "m -0.011951449,-0.53885114 0,0.14266384",
                "m 0.140317871,-0.53885114 0,0.14266384",
                "m -0.38626833,0.05057523 c 0.0255592,0.0016777 0.0370663,0.03000538 0.0613473,0.03881043 0.0234708,0.0066828 0.0475564,0.0043899 0.0713631,0.0025165 0.007966,-0.0041942 0.0530064,-0.03778425 0.055517,-0.04287323 0.0201495,-0.01674888 0.0473913,-0.05858754 0.0471458,-0.08232678 l 0.005008,-0.13145777 c 2.5649e-4,-0.006711 -0.0273066,-0.0279334 -0.0316924,-0.0330336 -0.005336,-0.006207 0.006996,-0.0660504 -0.003274,-0.0648984 -0.0115953,-0.004474 -0.0173766,5.5923e-4 -0.0345371,-0.007633 -0.004228,-0.0128063 -0.006344,-0.0668473 0.0101634,-0.0637967 0.0278325,0.001678 0.0452741,0.005061 0.0769157,-0.005732 0.0191776,0 0.08511053,-0.0609335 0.10414487,-0.0609335 l 0.16846578,8.3884e-4 c 0.0107679,0 0.0313968,0.0284032 0.036582,0.03359 0.0248412,0.0302766 0.0580055,0.0372558 0.10330712,0.0520893 0.011588,0.001398 0.0517858,-0.005676 0.0553021,0.002517 0.007968,0.0265354 0.005263,0.0533755 0.003112,0.0635227 -0.002884,0.0136172 -0.0298924,-1.9573e-4 -0.0313257,0.01742 -0.001163,0.0143162 -4.0824e-4,0.0399429 -0.004348,0.0576452 -0.0239272,0.024634 -0.0529159,0.0401526 -0.0429639,0.0501152 l -6.5709e-4,0.11251671 c 0.003074,0.02561265 0.0110277,0.05423115 0.0203355,0.07069203 0.026126,0.0576033 0.0800901,0.05895384 0.0862871,0.06055043 0.002843,8.3885e-4 0.24674425,0.0322815 0.38435932,0.16401046 0.0117097,0.0112125 0.0374559,0.0329274 0.0663551,0.12144199 0.0279253,0.0855312 0.046922,0.36424768 0.0375597,0.36808399 -0.0796748,0.0326533 -0.1879149,0.0666908 -0.31675221,0.0250534 -0.0160744,-0.005201 0.001703,-0.11017354 -0.008764,-0.16025522 -0.0107333,-0.0513567 3.4113e-4,-0.15113981 -0.11080061,-0.17089454 -0.0463118,-0.008221 -0.19606469,0.0178953 -0.30110236,0.0400631 -0.05001528,0.0105694 -0.117695,0.0171403 -0.15336817,0.0100102 -0.02204477,-0.004418 -0.15733412,-0.0337774 -0.18225582,-0.0400072 -0.0165302,-0.004138 -0.053376,-0.006263 -0.10905742,0.0111007 -0.0413296,0.0128902 -0.0635168,0.0443831 -0.0622649,0.0334027 9.1434e-4,-0.008025 0.001563,-0.46374837 -1.0743e-4,-0.47210603 z",
                "m 0.06341799,-0.8057541 c -0.02536687,-2.7961e-4 -0.06606003,0.0363946 -0.11502538,0.0716008 -0.06460411,0.0400268 -0.1414687,0.0117718 -0.20710221,-0.009675 -0.0622892,-0.0247179 -0.16166212,-0.004194 -0.17010213,0.0737175 0.001686,0.0453982 0.0182594,0.1160762 0.0734356,0.11898139 0.0927171,-0.0125547 0.18821206,-0.05389 0.28159685,-0.0236553 0.03728388,0.0164693 0.0439921,0.0419813 0.04709758,0.0413773 l 0.18295326,0 c 0.003105,5.5923e-4 0.009814,-0.0249136 0.0470976,-0.0413773 0.0933848,-0.0302347 0.18887978,0.0111007 0.2815969,0.0236553 0.0551762,-0.002908 0.0718213,-0.0735832 0.0735061,-0.11898139 -0.00844,-0.0779145 -0.10788342,-0.0984409 -0.17017266,-0.0737175 -0.0656335,0.0214464 -0.14249809,0.0497014 -0.20710215,0.009675 -0.0498479,-0.0358409 -0.09110973,-0.0731946 -0.11636702,-0.0715309 -4.5577e-4,-3.076e-5 -9.451e-4,-6.432e-5 -0.001412,-6.991e-5 z",
                "m -0.20848487,-0.33159571 c 0.29568578,0.0460357 0.5475498,0.0168328 0.5475498,0.0168328",
                "m -0.21556716,-0.26911875 c 0.29568578,0.0460329 0.55463209,0.0221175 0.55463209,0.0221175",
              ].each do |d|
                d.gsub!(/\d+\.\d+/) { |number| number.to_f * radius * 0.8 }
                rotated.add_element("path", "fill" => "none", "stroke" => "black", "stroke-width" => 0.2, "d" => d)
              end
            end
          end
          yield("labels").add_element("g", "transform" => transform) do |rotated|
            rotated.add_element("text", "dx" => radius, "dy" => -radius, "font-family" => fontfamily, "font-size" => fontsize, "fill" => "black", "stroke" => "none") do |text|
              text.add_text label
            end
          end unless type == :water
        end
      end
    rescue BadGpxKmlFile => e
      raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
    end
  end
  
  class OverlaySource < Source
    include Annotation
    include NoCreate
    include PathInParams
    
    def draw(map)
      gps = GPS.new(path)
      [ [ :tracks, "polyline", { "fill" => "none", "stroke" => "black", "stroke-width" => "0.4" } ],
        [ :areas, "polygon", { "fill" => "black", "stroke" => "none" } ]
      ].each do |feature, element, attributes|
        gps.send(feature).each do |list, name|
          points = svg_coords(list, Projection.wgs84, map).map { |point| point.join ?, }.join ?\s
          yield.add_element(element, attributes.merge("points" => points))
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
      %x[mogrify -units PixelsPerInch -density #{ppi} "#{png_path}"]
    end
  end
  
  module PSD
    def self.build(config, map, ppi, svg_path, composite_png_path, temp_dir, psd_path)
      xml = REXML::Document.new(svg_path.read)
      xml.elements["/svg/rect"].remove
      xml.elements.delete_all("/svg/g[@id]").map do |layer|
        id = layer.attributes["id"]
        puts "    Generating layer: #{id}"
        layer_svg_path, layer_png_path = %w[svg png].map { |ext| temp_dir + [ map.name, id, ext ].join(?.) }
        xml.elements["/svg"].add layer
        layer_svg_path.open("w") { |file| xml.write file }
        layer.remove
        Raster.build(config, map, ppi, layer_svg_path, temp_dir, layer_png_path)
        # Dodgy; Make sure there's a coloured pixel or imagemagick won't fill in the G and B channels in the PSD:
        %x[mogrify -label #{id} -fill "#FFFFFEFF" -draw 'color 0,0 point' "#{layer_png_path}"]
        layer_png_path
      end.unshift(composite_png_path).map do |layer_png_path|
        %Q[#{OP} "#{layer_png_path}" -units PixelsPerInch #{CP}]
      end.join(?\s).tap do |sequence|
        %x[convert #{sequence} "#{psd_path}"]
      end
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
      config["include"] << "nsw/topographic"
      puts "No layers specified. Adding nsw/topographic by default."
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
  class: CanvasSource
relief:
  class: ReliefSource
  altitude: 45
  azimuth: 315
  exaggeration: 2
  resolution: 30.0
  opacity: 0.3
  highlights: 20
  median: 30.0
  bilateral: 5
grid:
  class: GridSource
  interval: 1000
  label-spacing: 5
  fontsize: 7.8
  family: Arial Narrow
  labels:
    glow: 0.15
declination:
  class: DeclinationSource
  spacing: 1000
  width: 0.1
  colour: black
controls:
  class: ControlSource
  family: sans-serif
  fontsize: 14
  diameter: 7.0
  colour: "#880088"
  water:
    colour: blue
]
    
    layers = {}
    
    [ *config["import"] ].reverse.map do |file_or_hash|
      [ *file_or_hash ].flatten
    end.map do |file_or_path, layer_name|
      [ Pathname.new(file_or_path).expand_path, layer_name ]
    end.each do |path, layer_name|
      layer_name ||= path.basename(path.extname).to_s
      layers.merge! layer_name => { "class" => "ImportSource", "path" => path.to_s }
    end
    
    config["include"].map do |layer_name_or_path_or_hash|
      [ *layer_name_or_path_or_hash ].flatten
    end.each do |layer_name_or_path, resolution|
      path = Pathname.new(layer_name_or_path).expand_path
      layer_name, params = case
      when builtins[layer_name_or_path]
        [ layer_name_or_path, builtins[layer_name_or_path] ]
      when %w[.kml .gpx].include?(path.extname.downcase) && path.file?
        params = YAML.load %Q[---
          class: OverlaySource
          width: 0.4
          colour: black
          opacity: 0.4
          path: #{path}
        ]
        [ path.basename(path.extname).to_s, params ]
      else
        yaml = [ Pathname.pwd, Pathname.new(__FILE__).realdirpath.dirname + "sources", URI.parse(GITHUB_SOURCES) ].map do |root|
          root + "#{layer_name_or_path}.yml"
        end.inject(nil) do |memo, path|
          memo ||= path.read rescue nil
        end
        abort "Error: couldn't find source for '#{layer_name_or_path}'" unless yaml
        [ layer_name_or_path.gsub(?/, SEGMENT), YAML.load(yaml) ]
      end
      params.merge! "resolution" => resolution if resolution
      layers.merge! layer_name => params
    end
    
    layers.keys.select do |layer_name|
      config[layer_name]
    end.each do |layer_name|
      layers[layer_name].deep_merge! config[layer_name]
    end
    
    layers["relief"]["clips"] = layers.map do |layer_name, params|
      [ *params["relief-clips"] ].map { |sublayer_name| [ layer_name, sublayer_name ].join SEGMENT }
    end.inject(&:+) if layers["relief"]
    
    config["contour-interval"].tap do |interval|
      interval ||= map.scale < 40000 ? 10 : 20
      layers.each do |layer_name, params|
        params["exclude"] = [ *params["exclude"] ]
        [ *params["intervals-contours"] ].select do |candidate, sublayer|
          candidate != interval
        end.map(&:last).each do |sublayer|
          params["exclude"] += [ *sublayer ]
        end
      end
    end
    
    config["exclude"] = [ *config["exclude"] ].map { |layer_name| layer_name.gsub ?/, SEGMENT }
    config["exclude"].each { |layer_name| layers.delete layer_name }
    
    sources = layers.map do |layer_name, params|
      NSWTopo.const_get(params.delete "class").new(layer_name, params)
    end
    
    puts "Map details:"
    puts "  name: #{map.name}"
    puts "  size: %imm x %imm" % map.extents.map { |extent| 1000 * extent / map.scale }
    puts "  scale: 1:%i" % map.scale
    puts "  rotation: %.1f degrees" % map.rotation
    puts "  extent: %.1fkm x %.1fkm" % map.extents.map { |extent| 0.001 * extent }
    
    sources.reject(&:exist?).recover(InternetError, ServerError, BadLayerError).each do |source|
      source.create(map)
    end
    
    svg_name = "#{map.name}.svg"
    svg_path = Pathname.pwd + svg_name
    xml = svg_path.exist? ? REXML::Document.new(svg_path.read) : map.xml
    
    removals = config["exclude"].select do |layer_name|
      predicate = "@id='#{layer_name}' or starts-with(@id,'#{layer_name}#{SEGMENT}')"
      xml.elements["/svg/g[#{predicate}] | svg/defs/[#{predicate}]"]
    end
    
    updates = sources.reject do |source|
      xml.elements["/svg/g[@id='#{source.layer_name}' or starts-with(@id,'#{source.layer_name}#{SEGMENT}')]"] && FileUtils.uptodate?(svg_path, [ *source.path ])
    end
    
    additions = updates.reject do |source|
      xml.elements["/svg/g[@id='#{source.layer_name}' or starts-with(@id,'#{source.layer_name}#{SEGMENT}')]"]
    end
    
    Dir.mktmppath do |temp_dir|
      tmp_svg_path = temp_dir + svg_name
      tmp_svg_path.open("w") do |file|
        updates.each do |source|
          before, after = sources.map(&:layer_name).inject([[]]) do |memo, candidate|
            candidate == source.layer_name ? memo << [] : memo.last << candidate
            memo
          end
          neighbour = xml.elements.collect("/svg/g[@id]") do |sibling|
            sibling if after.any? do |layer_name|
              sibling.attributes["id"] == layer_name || sibling.attributes["id"].start_with?("#{layer_name}#{SEGMENT}")
            end
          end.compact.first
          begin
            puts "Compositing #{source.layer_name}"
            source.render_svg(xml, map) do |layer|
              neighbour ? xml.elements["/svg"].insert_before(neighbour, layer) : xml.elements["/svg"].add_element(layer)
            end
            puts "Styling #{source.layer_name}"
            source.rerender(xml, map)
          rescue BadLayerError => e
            puts "Failed to render #{source.layer_name}: #{e.message}"
          end
        end
        
        config["exclude"].map do |layer_name|
          predicate = "@id='#{layer_name}' or starts-with(@id,'#{layer_name}#{SEGMENT}')"
          xpath = "/svg/g[#{predicate}] | svg/defs/[#{predicate}]"
          [ layer_name, xpath ]
        end.select do |layer_name, xpath|
          xml.elements[xpath]
        end.each do |layer_name, xpath|
          puts "  Removing #{layer_name}"
          xml.elements.each(xpath, &:remove)
        end
        
        updates.each do |source|
          [ %w[below insert_before 1 to_a], %w[above insert_after last() reverse] ].select do |position, insert, predicate, order|
            config[position]
          end.each do |position, insert, predicate, order|
            config[position].select do |layer_name, sibling_name|
              layer_name == source.layer_name || layer_name.start_with?("#{source.layer_name}#{SEGMENT}")
            end.each do |layer_name, sibling_name|
              sibling = xml.elements["/svg/g[@id='#{sibling_name}' or starts-with(@id,'#{sibling_name}#{SEGMENT}')][#{predicate}]"]
              xml.elements.collect("/svg/g[@id='#{layer_name}' or starts-with(@id,'#{layer_name}#{SEGMENT}')]") do |layer|
                layer
              end.send(order).each do |layer|
                puts "  Moving #{layer.attributes['id']} #{position} #{sibling.attributes['id']}"
                layer.parent.send insert, sibling, layer
              end if sibling
            end
          end
        end
        
        REXML::XPath.match(xml, "/svg/g[@id]").select do |layer|
          sources.any? do |source|
            source.is_a?(ArcGISVector) && layer.attributes["id"] == "#{source.layer_name}#{SEGMENT}labels"
          end
        end.last.tap do |target|
          additions.select do |source|
            source.is_a?(ArcGISVector)
          end.map do |source|
            xml.elements["/svg/g[@id='#{source.layer_name}#{SEGMENT}labels']"]
          end.compact.reject do |layer|
            layer == target
          end.each do |layer|
            puts "  Moving #{layer.attributes['id']}" unless layer.elements.empty?
            target.parent.insert_before target, layer.remove
          end if target
        end unless config["leave-labels"]
        
        xml.elements.collect("/svg/defs/font", &:remove).each do |font|
          xml.elements["/svg/defs"].elements << font
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
    (formats.keys & %w[png tif gif jpg kmz psd]).each do |format|
      formats[format] ||= config["ppi"]
      formats["#{format[0]}#{format[2]}w"] = formats[format] if formats.include? "prj"
    end
    
    outstanding = (formats.keys & %w[png tif gif jpg kmz psd pdf pgw tfw gfw jgw map prj]).reject do |format|
      FileUtils.uptodate? "#{map.name}.#{format}", [ svg_path ]
    end
    
    Dir.mktmppath do |temp_dir|
      puts "Generating requested output formats:"
      outstanding.group_by do |format|
        formats[format]
      end.each do |ppi, group|
        raster_path = temp_dir + "#{map.name}.#{ppi}.png"
        if (group & %w[png tif gif jpg kmz psd]).any? || (ppi && group.include?("pdf"))
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
            when "psd"
              PSD.build config, map, ppi, svg_path, raster_path, temp_dir, output_path
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

# TODO: switch to Open3 for shelling out
# TODO: split LPIMapLocal roads into sealed & unsealed?
# TODO: change scale instead of using expand-glyph where possible
# TODO: add option for absolute measurements for rerendering?
# TODO: add nodata transparency in vegetation source?
# TODO: add include: option for ArcGIS sublayers?
# TODO: add import layers as per controls/overlays/etc?
# TODO: remove linked images from PDF output?
# TODO: put glow on control labels?
# TODO: add Relative_Height to topographic layers?
# TODO: find source for electricity transmission lines
# TODO: check georeferencing of aerial-google, aerial-nokia

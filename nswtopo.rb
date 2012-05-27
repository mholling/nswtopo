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
require 'tmpdir'
require 'yaml'
require 'fileutils'
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
end

module HashHelpers
  def deep_merge(hash)
    hash.inject(self.dup) do |result, (key, value)|
      result.merge(key => result[key].is_a?(Hash) && value.is_a?(Hash) ? result[key].deep_merge(value) : value)
    end
  end

  def to_query
    map { |key, value| "#{key}=#{value}" }.join ?&
  end
end
Hash.send :include, HashHelpers

module Enumerable
  def with_progress_interactive(message = nil)
    puts message if message
    bars, container, symbol = 70, "  [%s]", ?-
    Enumerator.new do |yielder|
      $stdout << container % (?\s * bars)
      each_with_index do |object, index|
        yielder << object
        filled = (index + 1) * bars / length
        content = (symbol * filled) << (?\s * (bars - filled))
        $stdout << "\r" << container % content
      end
      puts
    end
  end
  
  def with_progress_scripted(message = nil)
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

  def reproject(source_projection, target_projection)
    case first
    when Array then map { |point| point.reproject(source_projection, target_projection) }
    else %x[echo #{join(' ')} | gdaltransform -s_srs "#{source_projection}" -t_srs "#{target_projection}"].split(" ")[0..1].map(&:to_f)
    end
  end
end

module NSWTopo
  EARTH_RADIUS = 6378137.0
  WGS84 = "EPSG:4326"

  WINDOWS = !RbConfig::CONFIG["host_os"][/mswin|mingw/].nil?
  OP = WINDOWS ? '(' : '\('
  CP = WINDOWS ? ')' : '\)'
  ZIP = WINDOWS ? "7z a -tzip" : "zip"
  
  CONFIG = %q[---
name: map
scale: 25000
ppi: 300
rotation: 0
margin: 15
contours:
  interval: 10
  index: 100
  labels: 50
  source: 1
declination:
  spacing: 1000
  width: 0.1
  colour: "#000000"
grid:
  interval: 1000
  width: 0.1
  colour: "#000000"
  label-spacing: 5
  fontsize: 7.8
  family: Arial Narrow
relief:
  altitude: 45
  azimuth: 315
  exaggeration: 2
  resolution: 45.0
controls:
  colour: "#880088"
  family: Arial
  fontsize: 14
  diameter: 7.0
  thickness: 0.2
  water-colour: blue
render:
  pathways:
    expand: 0.5
    colours: 
      "#A39D93": "#363636"
  contours:
    expand: 0.7
    colours: 
      "#D6CAB6": "#805100"
      "#D6B781": "#805100"
  tracks:
    expand: 0.6
    colours:
      "#9C9C9C": "#363636"
  roads:
    expand: 0.6
    colours:
      "#9C9C9C": "#363636"
  cadastre:
    expand: 0.5
    opacity: 0.5
    colours:
      "#DCDCDC": "#999999"
      "#E4B3FF": "#999999"
  labels: 
    colours: 
      "#A87000": "#000000"
  water:
    opacity: 1
    colours:
      "#73A1E6": "#4985DF"
  LS_Hydroline:
    expand: 0.3
  LS_Watercourse:
    expand: 0.3
  MS_Hydroline:
    expand: 0.5
  MS_Watercourse:
    expand: 0.5
  SS_Watercourse:
    expand: 0.7
  VSS_Watercourse:
    expand: 0.7
  TN_Watercourse:
    expand: 0.7
  HydroArea:
    expand: 0.5
  Forestry:
    opacity: 1
    colours:
      "#38A800": "#9FD699"
  vegetation:
    opacity: 1
    colours:
      "#3F8C42": "#D5E9C8"
      "#A8A800": "#D5E9C8"
  relief:
    opacity: 0.3
    highlights: 20
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
      File.open(path, "w") do |file|
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
      @xml = REXML::Document.new(File.read path)
      case
      when @xml.elements["/gpx"] then class << self; include GPX; end
      when @xml.elements["/kml"] then class << self; include KML; end
      else raise BadGpxKmlFile.new(path)
      end
    rescue REXML::ParseException
      raise BadGpxKmlFile.new(path)
    end
  end
  
  class Map
    def initialize(config)
      @scale, @ppi = config.values_at("scale", "ppi")
      @resolution = @scale.to_f * 0.0254 / @ppi
      
      bounds_path = %w[bounds.kml bounds.gpx].find { |path| File.exists? path }
      wgs84_points = case
      when config["zone"] && config["eastings"] && config["northings"]
        config.values_at("eastings", "northings").inject(:product).reproject("+proj=utm +zone=#{config["zone"]} +south +ellps=WGS84 +datum=WGS84 +units=m +no_defs", WGS84)
      when config["longitudes"] && config["latitudes"]
        config.values_at("longitudes", "latitudes").inject(:product)
      when config["size"] && config["zone"] && config["easting"] && config["northing"]
        [ config.values_at("easting", "northing").reproject("+proj=utm +zone=#{config["zone"]} +south +ellps=WGS84 +datum=WGS84 +units=m +no_defs", WGS84) ]
      when config["size"] && config["longitude"] && config["latitude"]
        [ config.values_at("longitude", "latitude") ]
      when config["bounds"] || bounds_path
        config["bounds"] ||= bounds_path
        gps = GPS.new(config["bounds"])
        polygon = gps.areas.first
        waypoints = gps.waypoints.to_a
        config["margin"] = 0 unless waypoints.any?
        polygon ? polygon.first : waypoints.transpose.first
      else
        abort "Error: map extent must be provided as a bounds file, zone/eastings/northings, zone/easting/northing/size, latitudes/longitudes or latitude/longitude/size"
      end

      @projection_centre = wgs84_points.transpose.map { |coords| 0.5 * (coords.max + coords.min) }
      if config["utm"]
        zone = GridServer.zone(@projection_centre, WGS84)
        central_meridian = GridServer.central_meridian(zone)
        @projection = "+proj=utm +zone=#{zone} +south +ellps=WGS84 +datum=WGS84 +units=m +no_defs"
        @wkt = %Q{PROJCS["WGS_1984_UTM_Zone_#{zone}S",GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.017453292519943295]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",500000.0],PARAMETER["False_Northing",10000000.0],PARAMETER["central_meridian",#{central_meridian}],PARAMETER["Latitude_Of_Origin",0],PARAMETER["Scale_Factor",0.9996],UNIT["Meter",1.0]]}
      else
        @projection = "+proj=tmerc +lat_0=0.000000000 +lon_0=#{@projection_centre.first} +k=0.999600 +x_0=500000.000 +y_0=10000000.000 +ellps=WGS84 +datum=WGS84 +units=m"
        @wkt = %Q{PROJCS["",GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.017453292519943295]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",500000.0],PARAMETER["False_Northing",10000000.0],PARAMETER["Central_Meridian",#{@projection_centre.first}],PARAMETER["Latitude_Of_Origin",0.0],PARAMETER["Scale_Factor",0.9996],UNIT["Meter",1.0]]}
      end
      # proj_path = File.join(output_dir, "#{map_name}.prj")
      # File.open(proj_path, "w") { |file| file.puts projection }
      
      @declination = config["declination"]["angle"]
      config["rotation"] = -declination if config["rotation"] == "magnetic"

      if config["size"]
        sizes = config["size"].split(/[x,]/).map(&:to_f)
        abort("Error: invalid map size: #{config["size"]}") unless sizes.length == 2 && sizes.all? { |size| size > 0.0 }
        @extents = sizes.map { |size| size * 0.001 * scale }
        @rotation = config["rotation"]
        abort("Error: cannot specify map size and auto-rotation together") if @rotation == "auto"
        abort "Error: map rotation must be between +/-45 degrees" unless @rotation.abs <= 45
        @centre = @projection_centre.reproject(WGS84, @projection)
      else
        puts "Calculating map bounds..."
        bounding_points = wgs84_points.reproject(WGS84, projection)
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
      @dimensions = @extents.map { |extent| (extent / @resolution).ceil }
    rescue BadGpxKmlFile => e
      abort "Error: #{e.message}"
    end
    
    attr_reader :scale, :projection, :wkt, :bounds, :extents, :dimensions, :rotation, :ppi, :resolution
    
    def write_world_file(world_file_path, metres_per_pixel = @resolution)
      topleft = [ @centre, @extents.rotate_by(-@rotation * Math::PI / 180.0), [ :-, :+ ] ].transpose.map { |coord, extent, plus_minus| coord.send(plus_minus, 0.5 * extent) }
      WorldFile.write(topleft, metres_per_pixel, @rotation, world_file_path)
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
    
    def svg(&block)
      inches = @extents.map { |extent| extent / 0.0254 / @scale }
      REXML::Document.new.tap do |xml|
        xml << REXML::XMLDecl.new(1.0, "utf-8")
        attributes = {
          "version" => 1.1,
          "baseProfile" => "full",
          "xmlns" => "http://www.w3.org/2000/svg",
          "xmlns:xlink" => "http://www.w3.org/1999/xlink",
          "xmlns:ev" => "http://www.w3.org/2001/xml-events",
          "xml:space" => "preserve",
          "width"  => "#{inches[0]}in",
          "height" => "#{inches[1]}in",
          "viewBox" => "0 0 #{inches[0]} #{inches[1]}",
          "enable-background" => "new 0 0 #{inches[0]} #{inches[1]}"
        }
        xml.add_element("svg", attributes, &block)
      end
    end
    
    def svg_transform(inches_per_unit)
      if @rotation.zero?
        "scale(#{inches_per_unit})"
      else
        w, h = @bounds.map { |bound| (bound.max - bound.min) / 0.0254 / @scale }
        t = Math::tan(@rotation * Math::PI / 180.0)
        d = (t * t - 1) * Math::sqrt(t * t + 1)
        if t >= 0
          y = (t * (h * t - w) / d).abs
          x = (t * y).abs
        else
          x = -(t * (h + w * t) / d).abs
          y = -(t * x).abs
        end
        "translate(#{x} #{-y}) rotate(#{@rotation}) scale(#{inches_per_unit})"
      end
    end
  end
  
  InternetError = Class.new(Exception)
  ServerError = Class.new(Exception)
  BadGpxKmlFile = Class.new(Exception)
  BadLayerError = Class.new(Exception)
  
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
  
  module Bounds
    def self.transform(source_projection, target_projection, bounds)
      bounds.inject(:product).reproject(source_projection, target_projection).transpose.map { |coords| [ coords.min, coords.max ] }
    end

    def self.intersect?(bounds1, bounds2)
      [ bounds1, bounds2 ].transpose.map do |bound1, bound2|
        bound1.max > bound2.min && bound1.min < bound2.max
      end.inject(:&)
    end
  end
  
  class Color
    def initialize(hex)
      r, g, b = rgb = hex.scan(/\h\h/).map(&:hex)
      mx = rgb.max
      mn = rgb.min
      c  = mx - mn
      @hue = c.zero? ? nil : mx == r ? 60 * (g - b) / c : mx == g ? 60 * (b - r) / c + 120 : 60 * (r - g) / c + 240
      @lightness = 100 * (mx + mn) / 510
      @saturation = c.zero? ? 0 : 10000 * c / (100 - (2 * lightness - 100).abs) / 255
    end
    
    attr_accessor :hue, :saturation, :lightness
    
    def to_s
      c = (100 - (2 * lightness - 100).abs) * saturation * 255 / 10000
      x = hue && c * (60 - (hue % 120 - 60).abs) / 60
      m = 255 * lightness / 100 - c / 2
      rgb = case hue
      when   0..59  then [ m + c, m + x, m ]
      when  60..119 then [ m + x, m + c, m ]
      when 120..179 then [ m, m + c, m + x ]
      when 180..239 then [ m, m + x, m + c ]
      when 240..319 then [ m + x, m, m + c ]
      when 320..360 then [ m + c, m, m + x ]
      when nil      then [ 0, 0, 0 ]
      end
      "#%02x%02x%02x" % rgb
    end
  end
  
  class Server
    def initialize(params = {})
      @params = params
    end
  
    attr_reader :params
    
    def download(label, options, map)
      ext = options["ext"] || params["ext"] || "png"
      Dir.mktmpdir do |temp_dir|
        FileUtils.mv image(label, ext, options, map, temp_dir), Dir.pwd
      end unless File.exist?("#{label}.#{ext}")
    end
  end
  
  module RasterRenderer
    def render(label, options, map)
      ext = options["ext"] || params["ext"] || "png"
      filename = "#{label}.#{ext}"
      raise BadLayerError.new("raster image #{filename} not found") unless File.exists? filename
      href = if options["embed"] || params["embed"]
        Dir.mktmpdir do |temp_dir|
          optimised_path = File.join temp_dir, filename
          %x[convert "#{filename}" "#{optimised_path}"]
          type = %x[convert "#{optimised_path}" -format %m info:-].downcase
          base64 = Base64.encode64(File.read optimised_path)
          "data:image/#{type};base64,#{base64}"
        end
      else
        filename
      end
      image = REXML::Element.new("image")
      image.add_attributes(
        "id" => label,
        "transform" => "scale(#{1.0 / map.ppi})",
        "width" => map.dimensions[0],
        "height" => map.dimensions[1],
        "xlink:href" => href,
      )
      yield image
    end
  end
  
  class TiledServer < Server
    include RasterRenderer
    
    def image(label, ext, options, map, temp_dir)
      puts "Downloading: #{label}"
      tile_paths = tiles(options, map, temp_dir).map do |tile_bounds, resolution, tile_path|
        topleft = [ tile_bounds.first.min, tile_bounds.last.max ]
        WorldFile.write(topleft, resolution, 0, "#{tile_path}w")
        %Q["#{tile_path}"]
      end
    
      puts "Assembling: #{label}"
      tif_path = File.join(temp_dir, "#{label}.tif")
      tfw_path = File.join(temp_dir, "#{label}.tfw")
      vrt_path = File.join(temp_dir, "#{label}.vrt")
  
      %x[convert -size #{map.dimensions.join ?x} -units PixelsPerInch -density #{map.ppi} canvas:black -type TrueColor -depth 8 "#{tif_path}"]
      unless tile_paths.empty?
        %x[gdalbuildvrt "#{vrt_path}" #{tile_paths.join " "}]
        map.write_world_file(tfw_path)
        resample = params["resample"] || "cubic"
        projection = params["projection"]
        %x[gdalwarp -s_srs "#{projection}" -t_srs "#{map.projection}" -r #{resample} "#{vrt_path}" "#{tif_path}"]
      end
      
      File.join(temp_dir, "#{label}.#{ext}").tap do |output_path|
        %x[convert -quiet "#{tif_path}" "#{output_path}"]
      end
    end
  end
  
  class TiledMapServer < TiledServer
    def tiles(options, map, temp_dir)
      tile_sizes = params["tile_sizes"]
      tile_limit = params["tile_limit"]
      crops = params["crops"] || [ [ 0, 0 ], [ 0, 0 ] ]
    
      cropped_tile_sizes = [ tile_sizes, crops ].transpose.map { |tile_size, crop| tile_size - crop.inject(:+) }
      projection = params["projection"]
      bounds = Bounds.transform(map.projection, projection, map.bounds)
      extents = bounds.map { |bound| bound.max - bound.min }
      origins = bounds.transpose.first
      
      zoom, resolution, counts = (Math::log2(Math::PI * EARTH_RADIUS / map.resolution) - 7).ceil.downto(1).map do |zoom|
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
        tile_path = File.join(temp_dir, "tile.#{indices.join ?.}.png")
  
        cropped_centre = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
          origin + tile_size * (index + 0.5) * resolution
        end
        centre = [ cropped_centre, crops ].transpose.map { |coord, crop| coord - 0.5 * crop.inject(:-) * resolution }
        bounds = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
          [ origin + index * tile_size * resolution, origin + (index + 1) * tile_size * resolution ]
        end
  
        longitude, latitude = centre.reproject(projection, WGS84)
  
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
            File.open(tile_path, "wb") { |file| file << response.body }
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
    def tiles(options, map, temp_dir)
      bounds = Bounds.transform(map.projection, params["projection"], map.bounds)
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
        Bounds.intersect? bounds, attributes["bounds"]
      end
    
      if images_attributes.empty?
        []
      else
        tile_size = otdf ? 256 : params["tile_size"]
        format = images_attributes.one? ? { "type" => "jpg", "quality" => 90 } : { "type" => "png", "transparent" => true }
        images_attributes.map do |image, attributes|
          zoom = [ Math::log2(map.resolution / attributes["resolutions"].first).floor, 0 ].max
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
          tile_path = File.join(temp_dir, "tile.#{index}.#{format["type"]}")
          HTTP.get(uri) do |response|
            raise InternetError.new("no data received") if response.content_length.zero?
            begin
              xml = REXML::Document.new(response.body)
              raise ServerError.new(xml.elements["//Error"] ? xml.elements["//Error"].text.gsub("\n", " ") : "unexpected response")
            rescue REXML::ParseException
            end
            File.open(tile_path, "wb") { |file| file << response.body }
          end
          sleep params["interval"]
          [ tile_bounds, resolutions.first, tile_path]
        end
      end
    end
  end
  
  class ArcGIS < Server
    def dimensions(bounds, resolution)
      bounds.map { |bound| bound.max - bound.min }.map { |extent| (extent / resolution).ceil }
    end
    
    def tiles(bounds, resolution)
      service_tile_sizes = params["tile_sizes"]
      pixels = dimensions(bounds, resolution)
      counts = [ pixels, service_tile_sizes ].transpose.map { |pixel, tile_size| (pixel - 1) / tile_size + 1 }
      origins = [ bounds.first.min, bounds.last.max ]
      
      tile_sizes = [ counts, service_tile_sizes, pixels ].transpose.map do |count, tile_size, pixel|
        [ tile_size ] * (count - 1) << (((pixel - 1) % tile_size) + 1)
      end
      
      tile_bounds = [ tile_sizes, origins, [ :+, :- ] ].transpose.map do |sizes, origin, increment|
        boundaries = sizes.inject([0]) do |memo, size|
          memo << memo.last + size
        end.map do |pixels|
          origin.send(increment, pixels * resolution)
        end
        [ boundaries[0..-2], boundaries[1..-1] ].transpose.map(&:sort)
      end
      
      tile_offsets = tile_sizes.map do |sizes|
        sizes[0..-2].inject([0]) { |offsets, size| offsets << offsets.last + size }
      end
      
      [ tile_bounds, tile_sizes, tile_offsets ].map { |axes| axes.inject(:product) }.transpose
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
  end
  
  class VectorArcGIS < ArcGIS
    SEGMENT = ?.
    
    def initialize(*args)
      super(*args)
      params["ext"] = "svg"
    end
    
    def rerender(element, command, values)
      xpaths = case command
      when "opacity"
        "./@opacity"
      when "expand"
        %w[stroke-width stroke-dasharray stroke-miterlimit font-size].map { |name| ".//[@#{name}]/@#{name}" }
      when "stretch"
        ".//[@stroke-dasharray]/@stroke-dasharray"
      when "hue", "saturation", "lightness"
        %w[stroke fill].map { |name| ".//[@#{name}!='none']/@#{name}" }
      when "colours"
        %w[stroke fill].map { |name| values.keys.map { |colour| ".//[@#{name}='#{colour}']/@#{name}" } }.flatten
      end
      [ *xpaths ].each do |xpath|
        REXML::XPath.each(element, xpath) do |attribute|
          attribute.normalized = case command
          when "opacity"
            values.to_s
          when "expand", "stretch"
            attribute.value.split(/,\s*/).map(&:to_f).map { |size| size * values }.join(", ")
          when "hue", "saturation", "lightness"
            Color.new(attribute.value).tap { |color| color.send "#{command}=", values }.to_s
          when "colours"
            values[attribute.value] || attribute.value
          end
        end
      end
    end
    
    def image(label, ext, options, map, temp_dir)
      if params["cookie"] && !params["headers"]
        cookie = HTTP.head(URI.parse params["cookie"]) { |response| response["Set-Cookie"] }
        params["headers"] = { "Cookie" => cookie }
      end
      
      service = HTTP.get(service_uri(options, "f" => "json"), params["headers"]) do |response|
        JSON.parse(response.body).tap do |result|
          raise ServerError.new(result["error"]["message"]) if result["error"]
        end
      end
      layer_order = service["layers"].reverse.map.with_index { |layer, index| { layer["name"] => index } }.inject({}, &:merge)
      layer_names = service["layers"].map { |layer| layer["name"] }
      
      resolution = options["resolution"] || map.resolution
      transform = map.svg_transform(resolution / 0.0254 / map.scale)
      
      tile_list = tiles(map.bounds, resolution)
      
      downloads = %w[layers labels].select do |type|
        options[type]
      end.map do |type|
        case options[type]
        when Hash
          [ type, options[type] ]
        when String, Array
          [ type, { options["scale"] => [ *options[type] ] } ]
        when true
          [ type, { options["scale"] => true } ]
        end
      end.map do |type, scales_layers|
        scales_layers.map do |scale, layers|
          layer_options = case layers
          when Array
            ids = layers.map do |name|
              service["layers"].find { |layer| layer["name"] == name }.fetch("id")
            end
            { "layers" => "show:#{ids.join(?,)}" }
          when Hash
            ids, strings = layers.map do |name, definition|
              id = service["layers"].find { |layer| layer["name"] == name }.fetch("id")
              string = "#{id}:#{definition}"
              [ id, string ]
            end.transpose
            { "layers" => "show:#{ids.join(?,)}", "layerDefs" => strings.join(?;) }
          when true
            { }
          end.merge("dpi" => (scale || map.scale) * 0.0254 / resolution, "wkt" => map.wkt, "format" => "svg")
          xpath = type == "layers" ?
            "/svg//g[@id!='Labels' and not(.//g[@id])]" :
            "/svg//g[@id='Labels']"
          [ scale, layer_options, type, xpath ]
        end
      end.inject(:+)
          
      tilesets = tile_list.with_progress("Downloading: #{label}").map do |tile_bounds, tile_sizes, tile_offsets|
        tileset = downloads.map do |scale, layer_options, type, xpath|
          sleep params["interval"] if params["interval"]
          
          ################################################################################
          # temp_dir = File.join(Dir.pwd, "tmp")
          # temp_path = File.join temp_dir, [ type, scale, *tile_offsets, "svg" ].join(?.)
          # 
          # tile_data = case
          # when File.exists?(temp_path) then File.read(temp_path)
          # else get_tile(tile_bounds, tile_sizes, options.merge(layer_options))
          # end
          # if Dir.exists?(temp_dir) && !File.exists?(temp_path)
          #   File.write temp_path, tile_data
          # end
          # 
          # tile_data.gsub! /ESRITransportation\&?Civic/, %Q['ESRI Transportation &amp; Civic']
          # tile_data.gsub!  /ESRIEnvironmental\&?Icons/, %Q['ESRI Environmental &amp; Icons']
          # 
          # [ /id="(\w+)"/, /url\(#(\w+)\)"/, /xlink:href="#(\w+)"/ ].each do |regex|
          #   tile_data.gsub! regex do |match|
          #     case $1
          #     when "Labels", service["mapName"], *layer_names then match
          #     else match.sub $1, [ label, type, (scale || "native"), *tile_offsets, $1 ].join(SEGMENT)
          #     end
          #   end
          # end
          # 
          # [ REXML::Document.new(tile_data), scale, type, xpath ]
          ################################################################################
          tile_xml = get_tile(tile_bounds, tile_sizes, options.merge(layer_options)) do |tile_data|
            tile_data.gsub! /ESRITransportation\&?Civic/, %Q['ESRI Transportation &amp; Civic']
            tile_data.gsub!  /ESRIEnvironmental\&?Icons/, %Q['ESRI Environmental &amp; Icons']
          
            [ /id="(\w+)"/, /url\(#(\w+)\)"/, /xlink:href="#(\w+)"/ ].each do |regex|
              tile_data.gsub! regex do |match|
                case $1
                when "Labels", service["mapName"], *layer_names then match
                else match.sub $1, [ label, type, (scale || "native"), *tile_offsets, $1 ].join(SEGMENT) # TODO: native?
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
          ################################################################################
        end
        
        [ tileset, tile_sizes, tile_offsets ]
      end
      
      xml = map.svg do |svg|
        svg.add_element("defs") do |defs|
          tile_list.each do |tile_bounds, tile_sizes, tile_offsets|
            defs.add_element("clipPath", "id" => [ label, "tile", *tile_offsets ].join(SEGMENT)) do |clippath|
              clippath.add_element("rect", "width" => tile_sizes[0], "height" => tile_sizes[1])
            end
          end
        end
        
        layers = tilesets.find(lambda { [ [ ] ] }) do |tileset, _, _|
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
          { name => svg.add_element("g",
            "id" => [ label, name ].join(SEGMENT),
            "opacity" => opacity,
            "transform" => transform,
            "color-interpolation" => "linearRGB",
          )}
        end.inject({}, &:merge)
        
        tilesets.with_progress("Assembling: #{label}").each do |tileset, tile_sizes, tile_offsets|
          tileset.each do | tile_xml, scale, type, xpath|
            tile_xml.elements.each("//path[@d='']") { |path| path.parent.delete_element path }
            while tile_xml.elements["//g[not(*)]"]
              tile_xml.elements.each("//g[not(*)]") { |group| group.parent.delete_element group }
            end
            rerender(tile_xml, "expand", map.scale.to_f / scale) if scale && type == "layers"
            tile_xml.elements.collect(xpath) do |layer|
              [ layer, layer.attributes["id"] ]
            end.select do |layer, id|
              layers[id]
            end.each do |layer, id|
              tile_transform = "translate(#{tile_offsets.join ' '})"
              clip_path = "url(##{[ label, 'tile', *tile_offsets ].join(SEGMENT)})"
              layers[id].add_element("g", "transform" => tile_transform, "clip-path" => clip_path) do |tile|
                layer.elements.each { |element| tile << element }
              end
            end
          end
        end
      end
      
      File.join(temp_dir, "#{label}.svg").tap do |mosaic_path|
        File.open(mosaic_path, "w") { |file| xml.write file }
      end
    rescue REXML::ParseException => e
      abort "Bad XML received:\n#{e.message}"
    end
    
    def render(label, options, map, &block)
      svg = REXML::Document.new(File.read "#{label}.svg")
      equivalences = options["equivalences"] || {}
      renderings = options["render"].inject({}) do |memo, (layer_or_group, rendering)|
        [ *(equivalences[layer_or_group] || layer_or_group) ].each do |layer|
          memo[layer] ||= {}
          memo[layer] = memo[layer].merge(rendering)
        end
        memo
      end
      svg.elements.collect("/svg/g[@id]") do |layer|
        [ layer, layer.attributes["id"].split(SEGMENT).last ]
      end.each do |layer, id|
        renderings[id].each do |command, values|
          rerender(layer, command, values)
        end if renderings[id]
      end
      svg.elements.each("/svg/defs", &block)
      svg.elements.each("/svg/g[@id]", &block)
    end
  end
  
  class RasterArcGIS < ArcGIS
    include RasterRenderer
    
    def image(label, ext, options, map, temp_dir)
      scale = options["scale"] || map.scale
      resolution = options["resolution"] || map.resolution
      layer_options = { "dpi" => scale * 0.0254 / resolution, "wkt" => map.wkt, "format" => "png32" }
      
      dataset = tiles(map.bounds, resolution).with_progress("Downloading: #{label}").with_index.map do |(tile_bounds, tile_sizes, tile_offsets), tile_index|
        sleep params["interval"] if params["interval"]
        tile_path = File.join(temp_dir, "tile.#{tile_index}.png")
        File.open(tile_path, "wb") do |file|
          file << get_tile(tile_bounds, tile_sizes, options.merge(layer_options))
        end
        [ tile_bounds, tile_sizes, tile_offsets, tile_path ]
      end
      
      puts "Assembling: #{label}"
      
      File.join(temp_dir, "#{label}.#{ext}").tap do |mosaic_path|
        if map.rotation.zero?
          sequence = dataset.map do |_, tile_sizes, tile_offsets, tile_path|
            %Q[#{OP} "#{tile_path}" +repage -repage +#{tile_offsets[0]}+#{tile_offsets[1]} #{CP}]
          end.join " "
          resize = (options["resolution"] || options["scale"]) ? "-resize #{map.dimensions.join ?x}!" : ""
          %x[convert -units PixelsPerInch #{sequence} -compose Copy -layers mosaic -density #{map.ppi} #{resize} "#{mosaic_path}"]
        else
          tile_paths = dataset.map do |tile_bounds, _, _, tile_path|
            topleft = [ tile_bounds.first.first, tile_bounds.last.last ]
            WorldFile.write(topleft, resolution, 0, "#{tile_path}w")
            %Q["#{tile_path}"]
          end.join " "
          vrt_path = File.join(temp_dir, "#{label}.vrt")
          tif_path = File.join(temp_dir, "#{label}.tif")
          tfw_path = File.join(temp_dir, "#{label}.tfw")
          %x[gdalbuildvrt "#{vrt_path}" #{tile_paths}]
          %x[convert -size #{map.dimensions.join ?x} -units PixelsPerInch -density #{map.ppi} canvas:none -type TrueColorMatte -depth 8 "#{tif_path}"]
          map.write_world_file(tfw_path)
          %x[gdalwarp -s_srs "#{map.projection}" -t_srs "#{map.projection}" -dstalpha -r cubic "#{vrt_path}" "#{tif_path}"]
          %x[convert "#{tif_path}" -quiet "#{mosaic_path}"]
        end
      end
    end
  end
  
  class OneEarthDEMRelief < Server
    def image(label, ext, options, map, temp_dir)
      bounds = Bounds.transform(map.projection, WGS84, map.bounds)
      bounds = bounds.map { |bound| [ ((bound.first - 0.01) / 0.125).floor * 0.125, ((bound.last + 0.01) / 0.125).ceil * 0.125 ] }
      counts = bounds.map { |bound| ((bound.max - bound.min) / 0.125).ceil }
      resolution = params["resolution"]
      units_per_pixel = 0.125 / 300
  
      puts "Downloading: #{label}"
      tile_paths = [ counts, bounds ].transpose.map do |count, bound|
        boundaries = (0..count).map { |index| bound.first + index * 0.125 }
        [ boundaries[0..-2], boundaries[1..-1] ].transpose
      end.inject(:product).with_progress.map.with_index do |tile_bounds, index|
        tile_path = File.join(temp_dir, "tile.#{index}.png")
        bbox = tile_bounds.transpose.map { |corner| corner.join ?, }.join ?,
        query = {
          "request" => "GetMap",
          "layers" => "gdem",
          "srs" => WGS84,
          "width" => 300,
          "height" => 300,
          "format" => "image/png",
          "styles" => "short_int",
          "bbox" => bbox
        }.to_query
        uri = URI::HTTP.build :host => "onearth.jpl.nasa.gov", :path => "/wms.cgi", :query => URI.escape(query)
  
        HTTP.get(uri) do |response|
          File.open(tile_path, "wb") { |file| file << response.body }
          WorldFile.write([ tile_bounds.first.min, tile_bounds.last.max ], units_per_pixel, 0, "#{tile_path}w")
          sleep params["interval"]
        end
        %Q["#{tile_path}"]
      end
  
      vrt_path = File.join(temp_dir, "dem.vrt")
      %x[gdalbuildvrt "#{vrt_path}" #{tile_paths.join " "}]
      
      puts "Calculating: #{label}"
      relief_path = File.join(temp_dir, "#{label}-small.tif")
      tif_path = File.join(temp_dir, "#{label}.tif")
      tfw_path = File.join(temp_dir, "#{label}.tfw")
      map.write_world_file(tfw_path, resolution)
      dimensions = map.extents.map { |extent| (extent / resolution).ceil }
      ppi = 0.0254 * map.scale / resolution
      altitude = params["altitude"]
      azimuth = params["azimuth"]
      exaggeration = params["exaggeration"]
      %x[convert -size #{dimensions.join ?x} -units PixelsPerInch -density #{ppi} canvas:none -type Grayscale -depth 8 "#{tif_path}"]
      %x[gdaldem hillshade -s 111120 -alt #{altitude} -z #{exaggeration} -az #{azimuth} "#{vrt_path}" "#{relief_path}" -q]
      %x[gdalwarp -s_srs "#{WGS84}" -t_srs "#{map.projection}" -r bilinear "#{relief_path}" "#{tif_path}"]
      
      File.join(temp_dir, "#{label}.#{ext}").tap do |output_path|
        %x[convert "#{tif_path}" -quiet -type Grayscale -depth 8 "#{output_path}"]
      end
    end
    
    def render(label, options, map)
      ext = options["ext"] || params["ext"] || "png"
      Dir.mktmpdir do |temp_dir|
        resolution = params["resolution"]
        transform = "scale(#{resolution / map.scale / 0.0254})"
        hillshade_path = "#{label}.#{ext}"
        overlay_path = File.join temp_dir, "overlay.png"
        render = options["render"]["relief"]
        highlights = render["highlights"]
        shade = %Q["#{hillshade_path}" -level 0,65% -negate -alpha Copy -fill black +opaque black]
        sun = %Q["#{hillshade_path}" -level 80%,100% +level 0,#{highlights}% -alpha Copy -fill yellow +opaque yellow]
        %x[convert #{OP} #{shade} #{CP} #{OP} #{sun} #{CP} -composite "#{overlay_path}"]
        base64 = Base64.encode64(File.read overlay_path)
        dimensions = map.extents.map { |extent| (extent / resolution).ceil }
        image = REXML::Element.new("image")
        image.add_attributes(
          "opacity" => render["opacity"],
          "transform" => transform,
          "width" => dimensions[0],
          "height" => dimensions[1],
          "image-rendering" => "optimizeQuality",
          "xlink:href" => "data:image/png;base64,#{base64}",
        )
        yield image
      end
    end
  end
  
  class CanvasServer < Server
    include RasterRenderer
    
    def download(*args)
    end
  end
  
  class AnnotationServer < Server
    def download(*args)
    end
    
    def render(label, options, map)
      group = REXML::Element.new("g")
      group.add_attribute("transform", map.svg_transform(1))
      draw(group, options, map) do |coords, projection|
        easting, northing = coords.reproject(projection, map.projection)
        [ easting - map.bounds.first.first, map.bounds.last.last - northing ].map do |metres|
          metres / map.scale / 0.0254
        end
      end
      yield group
    end
  end
  
  class DeclinationServer < AnnotationServer
    def draw(group, options, map)
      centre = Bounds.transform(map.projection, WGS84, map.bounds).map { |bound| 0.5 * bound.inject(:+) }
      projection = "+proj=tmerc +lat_0=0.000000000 +lon_0=#{centre[0]} +k=0.999600 +x_0=500000.000 +y_0=10000000.000 +ellps=WGS84 +datum=WGS84 +units=m"
      spacing = params["spacing"] / Math::cos(map.declination * Math::PI / 180.0)
      bounds = Bounds.transform(map.projection, projection, map.bounds)
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
        group.add_element("path", "d" => d, "stroke" => params["colour"], "stroke-width" => params["width"] / 25.4)
      end
    end
  end
  
  class GridServer < AnnotationServer
    def self.zone(coords, projection)
      (coords.reproject(projection, WGS84).first / 6).floor + 31
    end
    
    def self.central_meridian(zone)
      (zone - 31) * 6 + 3
    end
  
    def draw(group, options, map)
      interval = params["interval"]
      label_spacing = params["label-spacing"]
      label_interval = label_spacing * interval
      fontfamily = params["family"]
      fontsize = params["fontsize"] / 72.0
      
      map.bounds.inject(:product).map do |corner|
        GridServer.zone(corner, map.projection)
      end.inject do |range, zone|
        [ *range, zone ].min .. [ *range, zone ].max
      end.each do |zone|
        projection = "+proj=utm +zone=#{zone} +south +ellps=WGS84 +datum=WGS84 +units=m +no_defs"
        eastings, northings = Bounds.transform(map.projection, projection, map.bounds).map do |bound|
          (bound[0] / interval).floor .. (bound[1] / interval).ceil
        end.map do |counts|
          counts.map { |count| count * interval }
        end
        grid = eastings.map do |easting|
          northings.reverse.map do |northing|
            [ easting, northing ]
          end.map do |coords|
            [ GridServer.zone(coords, projection) == zone, coords ]
          end
        end
        [ grid, grid.transpose ].each.with_index do |gridlines, index|
          gridlines.each do |gridline|
            line = gridline.select(&:first).map(&:last)
            line.map do |coords|
              yield coords, projection
            end.map do |point|
              point.join(" ")
            end.join(" L").tap do |d|
              group.add_element("path", "d" => "M#{d}", "stroke-width" => params["width"] / 25.4, "stroke" => params["colour"])
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
                  transform = "translate(#{middle.join ' '}) rotate(#{angle})"
                  [ [ "white", "white" ], [ params["colour"], "none" ] ].each do |fill, stroke|
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
  
  class ControlServer < AnnotationServer
    def draw(group, options, map)
      return unless params["file"]
      radius = params["diameter"] / 25.4 / 2
      strokewidth = params["thickness"] / 25.4
      fontfamily = params["family"]
      fontsize = params["fontsize"] / 72.0
      
      [ [ /\d{2,3}/, :circle,   params["colour"] ],
        [ /HH/,      :triangle, params["colour"] ],
        [ /W/,       :water,    params["water-colour"] ],
      ].each do |selector, type, colour|
        GPS.new(params["file"]).waypoints.map do |waypoint, name|
          [ yield(waypoint, WGS84), name[selector] ]
        end.select do |point, label|
          label
        end.each do |point, label|
          transform = "translate(#{point.join ' '}) rotate(#{-map.rotation})"
          group.add_element("g", "transform" => transform) do |rotated|
            case type
            when :circle
              rotated.add_element("circle", "r"=> radius, "fill" => "none", "stroke" => colour, "stroke-width" => strokewidth)
            when :triangle
              points = [ -90, -210, -330 ].map do |angle|
                [ radius, 0 ].rotate_by(angle * Math::PI / 180.0)
              end.map { |vertex| vertex.join ?, }.join " "
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
  
  class OverlayServer < AnnotationServer
    def draw(group, options, map)
      width = (options["width"] || 0.5) / 25.4
      colour = options["colour"] || "black"
      opacity = options["opacity"] || 0.3
      gps = GPS.new(options["path"])
      [ [ :tracks, "polyline", { "fill" => "none", "stroke" => colour, "stroke-width" => width } ],
        [ :areas, "polygon", { "fill" => colour, "stroke" => "none" } ]
      ].each do |feature, element, attributes|
        gps.send(feature).each do |list, name|
          points = list.map { |coords| yield(coords, WGS84).join ?, }.join " "
          group.add_element(element, attributes.merge("points" => points, "opacity" => opacity))
        end
      end
    rescue BadGpxKmlFile => e
      raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
    end
  end
  
  # module KMZ
  #   TILE_SIZE = 512
  #   TILE_FORMAT = "gif"
  #   
  #   def self.style
  #     lambda do |style|
  #       style.add_element("ListStyle", "id" => "hideChildren") do |list_style|
  #         list_style.add_element("listItemType") { |type| type.text = "checkHideChildren" }
  #       end
  #     end
  #   end
  #   
  #   def self.lat_lon_box(bounds)
  #     lambda do |box|
  #       [ %w[west east south north], bounds.flatten ].transpose.each do |limit, value|
  #         box.add_element(limit) { |lim| lim.text = value }
  #       end
  #     end
  #   end
  #   
  #   def self.region(bounds)
  #     lambda do |region|
  #       region.add_element("Lod") do |lod|
  #         lod.add_element("minLodPixels") { |min| min.text = TILE_SIZE / 2 }
  #         lod.add_element("maxLodPixels") { |max| max.text = -1 }
  #       end
  #       region.add_element("LatLonAltBox", &lat_lon_box(bounds))
  #     end
  #   end
  #   
  #   def self.network_link(bounds, path)
  #     lambda do |network|
  #       network.add_element("Region", &region(bounds))
  #       network.add_element("Link") do |link|
  #         link.add_element("href") { |href| href.text = path }
  #         link.add_element("viewRefreshMode") { |mode| mode.text = "onRegion" }
  #         link.add_element("viewFormat")
  #       end
  #     end
  #   end
  #   
  #   def self.build(map_name, bounds, projection, scaling, image_path, kmz_path)
  #     wgs84_bounds = Bounds.transform(projection, WGS84, bounds)
  #     degrees_per_pixel = 180.0 * scaling.metres_per_pixel / Math::PI / EARTH_RADIUS
  #     dimensions = wgs84_bounds.map { |bound| bound.reverse.inject(:-) / degrees_per_pixel }
  #     max_zoom = Math::log2(dimensions.max).ceil - Math::log2(TILE_SIZE)
  #     topleft = [ wgs84_bounds.first.min, wgs84_bounds.last.max ]
  #     
  #     Dir.mktmpdir do |temp_dir|
  #       pyramid = 0.upto(max_zoom).map do |zoom|
  #         resolution = degrees_per_pixel * 2**(max_zoom - zoom)
  #         degrees_per_tile = resolution * TILE_SIZE
  #         counts = wgs84_bounds.map { |bound| (bound.reverse.inject(:-) / degrees_per_tile).ceil }
  #         dimensions = counts.map { |count| count * TILE_SIZE }
  #         resample = zoom == max_zoom ? "near" : "bilinear"
  # 
  #         tfw_path = File.join(temp_dir, "zoom-#{zoom}.tfw")
  #         tif_path = File.join(temp_dir, "zoom-#{zoom}.tif")
  #         WorldFile.write(topleft, resolution, 0, tfw_path)
  #         %x[convert -size #{dimensions.join ?x} canvas:none -type TrueColorMatte -depth 8 "#{tif_path}"]
  #         %x[gdalwarp -s_srs "#{projection}" -t_srs "#{WGS84}" -r #{resample} -dstalpha "#{image_path}" "#{tif_path}"]
  # 
  #         indices_bounds = [ topleft, counts, [ :+, :- ] ].transpose.map do |coord, count, increment|
  #           boundaries = (0..count).map { |index| coord.send increment, index * degrees_per_tile }
  #           [ boundaries[0..-2], boundaries[1..-1] ].transpose.map(&:sort)
  #         end.map do |tile_bounds|
  #           tile_bounds.each.with_index.to_a
  #         end.inject(:product).map(&:transpose).map do |tile_bounds, indices|
  #           { indices => tile_bounds }
  #         end.inject({}, &:merge)
  #         { zoom => indices_bounds }
  #       end.inject({}, &:merge)
  #       
  #       kmz_dir = File.join(temp_dir, map_name)
  #       Dir.mkdir(kmz_dir)
  #       
  #       pyramid.each do |zoom, indices_bounds|
  #         zoom_dir = File.join(kmz_dir, zoom.to_s)
  #         Dir.mkdir(zoom_dir)
  #       
  #         tif_path = File.join(temp_dir, "zoom-#{zoom}.tif")
  #         indices_bounds.map do |indices, tile_bounds|
  #           index_dir = File.join(zoom_dir, indices.first.to_s)
  #           Dir.mkdir(index_dir) unless Dir.exists?(index_dir)
  #           tile_kml_path = File.join(index_dir, "#{indices.last}.kml")
  #           tile_img_path = File.join(index_dir, "#{indices.last}.#{TILE_FORMAT}")
  #           crops = indices.map { |index| index * TILE_SIZE }
  #           %x[convert "#{tif_path}" -quiet -crop #{TILE_SIZE}x#{TILE_SIZE}+#{crops.join ?+} +repage "#{tile_img_path}"]
  #           
  #           xml = REXML::Document.new
  #           xml << REXML::XMLDecl.new(1.0, "UTF-8")
  #           xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1") do |kml|
  #             kml.add_element("Document") do |document|
  #               document.add_element("Style", &style)
  #               document.add_element("Region", &region(tile_bounds))
  #               document.add_element("GroundOverlay") do |overlay|
  #                 overlay.add_element("drawOrder") { |draw_order| draw_order.text = zoom }
  #                 overlay.add_element("Icon") do |icon|
  #                   icon.add_element("href") { |href| href.text = "#{indices.last}.#{TILE_FORMAT}" }
  #                 end
  #                 overlay.add_element("LatLonBox", &lat_lon_box(tile_bounds))
  #               end
  #               if zoom < max_zoom
  #                 indices.map do |index|
  #                   [ 2 * index, 2 * index + 1 ]
  #                 end.inject(:product).select do |subindices|
  #                   pyramid[zoom + 1][subindices]
  #                 end.each do |subindices|
  #                   document.add_element("NetworkLink", &network_link(pyramid[zoom + 1][subindices], "../../#{[ zoom+1, *subindices ].join ?/}.kml"))
  #                 end
  #               end
  #             end
  #           end
  #           File.open(tile_kml_path, "w") { |file| file << xml }
  #         end
  #       end
  #       
  #       xml = REXML::Document.new
  #       xml << REXML::XMLDecl.new(1.0, "UTF-8")
  #       xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1") do |kml|
  #         kml.add_element("Document") do |document|
  #           document.add_element("Name") { |name| name.text = map_name }
  #           document.add_element("Style", &style)
  #           document.add_element("NetworkLink", &network_link(pyramid[0][[0,0]], "0/0/0.kml"))
  #         end
  #       end
  #       kml_path = File.join(kmz_dir, "doc.kml")
  #       File.open(kml_path, "w") { |file| file << xml }
  #       
  #       temp_kmz_path = File.join(temp_dir, "#{map_name}.kmz")
  #       Dir.chdir(kmz_dir) { %x[#{ZIP} -r "#{temp_kmz_path}" *] }
  #       FileUtils.mv(temp_kmz_path, kmz_path)
  #     end
  #   end
  # end
  
  def self.run
    default_config = YAML.load(CONFIG)
    %w[controls.kml controls.gpx].select do |filename|
      File.exists? filename
    end.each do |filename|
      default_config["controls"]["file"] ||= filename
    end
    config_path = "config.yml"
    bounds_path = %w[bounds.kml bounds.gpx].find { |path| File.exists? path }
    user_config = begin
      case
      when File.exists?(config_path)
        YAML.load File.read(config_path)
      when bounds_path
        { "bounds" => bounds_path }
      else
        abort "Error: no configuration or bounds file found."
      end
    rescue ArgumentError, SyntaxError => e
      abort "Error in configuration file: #{e.message}"
    end
    config = default_config.deep_merge user_config
    config["include"] = [ *config["include"] ]
    
    map = Map.new(config)
    
    sixmaps_vector = VectorArcGIS.new(
      "host" => "mapsq.six.nsw.gov.au",
      "folder" => "sixmaps",
      "tile_sizes" => [ 2048, 2048 ],
      "interval" => 0.1,
    )
    sixmaps_raster = RasterArcGIS.new(
      "host" => "mapsq.six.nsw.gov.au",
      "folder" => "sixmaps",
      "tile_sizes" => [ 2048, 2048 ],
      "interval" => 0.1,
      "embed" => config["embed"],
    )
    atlas = VectorArcGIS.new(
      "host" => "atlas.nsw.gov.au",
      "instance" => "arcgis1",
      "folder" => "atlas",
      "cookie" => "http://atlas.nsw.gov.au/",
      "tile_sizes" => [ 2048, 2048 ],
      "interval" => 0.1,
    )
    lpi_ortho = LPIOrthoServer.new(
      "host" => "lite.maps.nsw.gov.au",
      "tile_size" => 1024,
      "interval" => 1.0,
      "projection" => "EPSG:3308",
      "embed" => config["embed"],
    )
    nokia_maps = TiledMapServer.new(
      "uri" => "http://m.ovi.me/?c=${latitude},${longitude}&t=${name}&z=${zoom}&h=${vsize}&w=${hsize}&f=${format}&nord&nodot",
      "projection" => "EPSG:3857",
      "tile_sizes" => [ 1024, 1024 ],
      "interval" => 1.2,
      "crops" => [ [ 0, 0 ], [ 26, 0 ] ],
      "tile_limit" => 250,
      "retries_on_blank" => 1,
      "embed" => config["embed"],
    )
    google_maps = TiledMapServer.new(
      "uri" => "http://maps.googleapis.com/maps/api/staticmap?zoom=${zoom}&size=${hsize}x${vsize}&scale=1&format=${format}&maptype=${name}&sensor=false&center=${latitude},${longitude}",
      "projection" => "EPSG:3857",
      "tile_sizes" => [ 640, 640 ],
      "interval" => 1.2,
      "crops" => [ [ 0, 0 ], [ 30, 0 ] ],
      "tile_limit" => 250,
      "embed" => config["embed"],
    )
    oneearth_relief = OneEarthDEMRelief.new({ "interval" => 0.3 }.merge config["relief"])
    declination_server = DeclinationServer.new(config["declination"])
    control_server = ControlServer.new(config["controls"])
    grid_server = GridServer.new(config["grid"])
    canvas_server = CanvasServer.new("embed" => config["embed"])
    
    layers = {
      "reference-1" => {
        "server" => lpi_ortho,
        "image" => "/OTDF_Imagery/NSWTopoS2v2.ecw",
        "otdf" => true,
        "ext" => "png",
      },
      "reference-2" => {
        "server" => sixmaps_raster,
        "service" => "NSWTopo",
        "image" => true,
        "ext" => "png",
      },
      "aerial-lpi-eastcoast" => {
        "server" => lpi_ortho,
        "image" => "/Imagery/lr94ortho1m.ecw",
        "ext" => "jpg",
      },
      # "aerial-lpi-sydney" => {
      #   "server" => lpi_ortho,
      #   "config" => "/SydneyImagesConfig.js",
      #   "ext" => "jpg",
      # },
      # "aerial-lpi-towns" => {
      #   "server" => lpi_ortho,
      #   "config" => "/NSWRegionalCentresConfig.js",
      #   "ext" => "jpg",
      # },
      "aerial-google" => {
        "server" => google_maps,
        "name" => "satellite",
        "format" => "jpg",
        "ext" => "jpg",
      },
      "aerial-nokia" => {
        "server" => nokia_maps,
        "name" => 1,
        "format" => 1,
        "ext" => "jpg",
      },
      "aerial-lpi-ads40" => {
        "server" => lpi_ortho,
        "config" => "/ADS40ImagesConfig.js",
        "ext" => "jpg",
      },
      "aerial-webm" => {
        "server" => sixmaps_raster,
        "service" => "Best_WebM",
        "image" => true,
        "ext" => "jpg",
      },
      # "aerial-best" => {
      #   "server" => sixmaps_raster,
      #   "service" => "LPI_Imagery_Best",
      #   "ext" => "jpg",
      # },
      # "vegetation" => {
      #   "server" => atlas,
      #   "service" => "Economy_Landuse",
      #   "resolution" => 0.55,
      #   "layers" => { nil => { "Landuse" => %q[LU_NSWMajo='Conservation Area' OR LU_NSWMajo LIKE 'Tree%'] } },
      #   "equivalences" => { "vegetation" => %w[Landuse] },
      # },
      "plantation" => {
        "server" => atlas,
        "service" => "Economy_Forestry",
        "resolution" => 0.55,
        "layers" => { nil => { "Forestry" => %q[Classification='Plantation forestry'] } },
        "equivalences" => { "plantation" => %w[Forestry] },
      },
      "canvas" => {
        "server" => canvas_server,
        "ext" => "png",
      },
      "topographic" => {
        "server" => sixmaps_vector,
        "service" => "LPIMap",
        "resolution" => 0.55,
        "layers" => {
          4500 => {
            "LS_Roads_onbridge" => %q["functionhierarchy" = 9 AND "classsubtype" = 6 AND NOT "roadontype" IN (1,3)],
            "LS_Roads_onground" => %q["functionhierarchy" = 9 AND "classsubtype" = 6 AND "roadontype" = 1],
          },
          # TODO: move all roads to the 1:9000 set?
          9000 => %w[TransportFacilityLine GeneralCulturalLine MS_LocalRoads GeneralCulturalPoint LS_Watercourse LS_Hydroline Rural_Property Lot LS_Contour GeneralCulturalArea],
          nil => %w[LS_PlacePoint LS_GeneralCulturalPoint PointOfInterest DLSPoint DLSLine MS_BuildingComplexPoint MS_RoadNameExtent_Labels MS_Roads_Labels TransportFacilityPoint MS_Railway MS_Roads MS_Tracks_onground MS_Roads_intunnel AncillaryHydroPoint AncillaryHydroPoint_Bore DLSArea_overwater FuzzyExtentLine Runway VSS_Oceans HydroArea MS_Watercourse MS_Hydroline DLSArea_underwater SS_Watercourse VSS_Watercourse TN_Watercourse Urban_Areas]
        },
        "labels" => {
          15000 => %w[LS_PlacePoint LS_GeneralCulturalPoint PointOfInterest DLSPoint DLSLine MS_BuildingComplexPoint GeneralCulturalPoint MS_RoadNameExtent_Labels MS_Roads_Labels TransportFacilityPoint MS_Railway MS_Roads MS_LocalRoads MS_Tracks_onground MS_Roads_intunnel AncillaryHydroPoint AncillaryHydroPoint_Bore TransportFacilityLine GeneralCulturalLine DLSArea_overwater FuzzyExtentLine Runway VSS_Oceans HydroArea LS_Watercourse LS_Hydroline MS_Watercourse MS_Hydroline DLSArea_underwater SS_Watercourse VSS_Watercourse TN_Watercourse Rural_Property MS_Contour Urban_Areas],
          # GeneralCulturalArea # TODO: labels?
        },
        "equivalences" => {
          "contours" => %w[LS_Contour MS_Contour],
          "water" => %w[TN_Watercourse VSS_Watercourse SS_Watercourse MS_Hydroline MS_Watercourse LS_Hydroline LS_Watercourse VSS_Oceans HydroArea],
          "pathways" => %w[LS_Roads_onground LS_Roads_onbridge],
          "tracks" => %w[MS_Tracks_onground],
          "roads" => %w[MS_Roads MS_LocalRoads MS_Roads_intunnel],
          "cadastre" => %w[Rural_Property Lot],
          "labels" => %w[Labels],
        },
      },
      "holdings" => {
        "server" => sixmaps_vector,
        "service" => "LHPA",
        "layers" => %w[Holdings],
        "labels" => %w[Holdings],
      },
      "relief" => {
        "server" => oneearth_relief,
        "ext" => "png",
      },
      "declination" => {
        "server" => declination_server,
      },
      "grid" => {
        "server" => grid_server,
      },
    }
    
    labels = %w[topographic]
    labels += layers.keys.select { |label| config["include"].any? { |match| label[match] } }
    
    (config["overlays"] || {}).each do |filename_or_path, options|
      label = File.split(filename_or_path).last.partition(/\.\w+$/).first
      layers.merge!(label => (options || {}).merge("server" => OverlayServer.new, "path" => filename_or_path))
      labels << label
    end
    
    if config["controls"]["file"]
      layers.merge!("controls" => { "server" => control_server})
      labels << "controls"
    end
    
    puts "Map details:"
    puts "  size: %imm x %imm" % map.extents.map { |extent| 1000 * extent / map.scale }
    puts "  scale: 1:%i" % map.scale
    puts "  rotation: %.1f degrees" % map.rotation
    puts "  rasters: %i x %i (%.1fMpx) @ %i ppi" % [ *map.dimensions, 0.000001 * map.dimensions.inject(:*), map.ppi ]
    
    labels.recover(InternetError, ServerError).each do |label|
      options = layers[label]
      options["server"].download(label, options, map)
    end
    
    filename = "#{config['name']}.svg"
    Dir.mktmpdir do |temp_dir|
      svg_path = File.join(temp_dir, filename)
      File.open(svg_path, "w") do |file|
        map.svg do |svg|
          layers.select do |label, options|
            labels.include? label
          end.each do |label, options|
            puts "Rendering #{label}"
            begin
              svg.add_element("g", "id" => label) do |group|
                options["server"].render(label, options.merge("render" => config["render"]), map) do |element|
                  group.elements << element
                end
              end
            rescue BadLayerError => e
              puts "Failed to render #{label}: #{e.message}"
            end
          end
          fonts = svg.elements.collect("//[@font-family]") { |element| element.attributes["font-family"] }.uniq
          if fonts.any?
            puts "Fonts required for #{filename}"
            fonts.sort.each { |font| puts "  #{font}" }
          end
        end.write(file)
      end
      FileUtils.mv svg_path, Dir.pwd
    end unless File.exists? filename
    
#     
#     oziexplorer_formats = %w[bmp png gif] & formats
#     unless oziexplorer_formats.empty?
#       oziexplorer_path = File.join(output_dir, "#{map_name}.map")
#       image_file = "#{map_name}.#{oziexplorer_formats.first}"
#       image_path = File.join(output_dir, image_file)
#       corners = dimensions.map do |dimension|
#         [ -0.5 * dimension * scaling.metres_per_pixel, 0.5 * dimension * scaling.metres_per_pixel ]
#       end.inject(:product).map do |offsets|
#         [ centre, offsets.rotate_by(rotation * Math::PI / 180.0) ].transpose.map { |coord, offset| coord + offset }
#       end
#       wgs84_corners = corners.reproject(projection, WGS84).values_at(1,3,2,0)
#       pixel_corners = [ dimensions, [ :to_a, :reverse ] ].transpose.map { |dimension, order| [ 0, dimension ].send(order) }.inject(:product).values_at(1,3,2,0)
#       calibration_strings = [ pixel_corners, wgs84_corners ].transpose.map.with_index do |(pixel_corner, wgs84_corner), index|
#         dmh = [ wgs84_corner, [ [ ?E, ?W ], [ ?N, ?S ] ] ].transpose.reverse.map do |coord, hemispheres|
#           [ coord.abs.floor, 60 * (coord.abs - coord.abs.floor), coord > 0 ? hemispheres.first : hemispheres.last ]
#         end
#         "Point%02i,xy,%i,%i,in,deg,%i,%f,%c,%i,%f,%c,grid,,,," % [ index+1, pixel_corner, dmh ].flatten
#       end
#       File.open(oziexplorer_path, "w") do |file|
#         file << %Q[OziExplorer Map Data File Version 2.2
# #{map_name}
# #{image_file}
# 1 ,Map Code,
# WGS 84,WGS84,0.0000,0.0000,WGS84
# Reserved 1
# Reserved 2
# Magnetic Variation,,,E
# Map Projection,Transverse Mercator,PolyCal,No,AutoCalOnly,Yes,BSBUseWPX,No
# #{calibration_strings.join ?\n}
# Projection Setup,0.000000000,#{projection_centre.first},0.999600000,500000.00,10000000.00,,,,,
# Map Feature = MF ; Map Comment = MC     These follow if they exist
# Track File = TF      These follow if they exist
# Moving Map Parameters = MM?    These follow if they exist
# MM0,Yes
# MMPNUM,4
# #{pixel_corners.map.with_index { |pixel_corner, index| "MMPXY,#{index+1},#{pixel_corner.join ?,}" }.join ?\n}
# #{wgs84_corners.map.with_index { |wgs84_corner, index| "MMPLL,#{index+1},#{wgs84_corner.join ?,}" }.join ?\n}
# MM1B,#{scaling.metres_per_pixel}
# MOP,Map Open Position,0,0
# IWH,Map Image Width/Height,#{dimensions.join ?,}
# ].gsub(/\r\n|\r|\n/, "\r\n")
#       end
#     end
  end
end

Signal.trap("INT") do
  abort "\nHalting execution. Run the script again to resume."
end

if File.identical?(__FILE__, $0)
  NSWTopo.run
end

# TODO: solve tile-boundary gap problem
# TODO: option to allow for tiles not to be clipped (e.g. for labels)?
# TODO: rendering final SVG back to PNG/GeoTIFF with georeferencing
# TODO: allow user-selectable contours
# TODO: apply "expand" rendering command to point features an fill areas as well as lines?
# TODO: add "colour" rendering option to specify single colour
# TODO: put long command lines into text file...
# TODO: allow configuration to specify patterns..?
# TODO: figure out why Batik won't render...


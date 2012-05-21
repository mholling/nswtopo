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
  
  CONFIG = %q[
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
grid:
  interval: 1000
  labels:
    style: grid
    spacing: 5
  fontsize: 7.8
  family: Arial Narrow
  weight: 200
relief:
  altitude: 45
  azimuth: 315
  exaggeration: 1
controls:
  family: Arial
  fontsize: 14
  weight: 200
  diameter: 7.0
  thickness: 0.2
  waterdrop-size: 4.5
formats:
- png
compose:
- topographic
render:
  LS_Roads_onground:
    expand: 2
    lightness: 20
  LS_Roads_onbridge:
    expand: 1.5
    colours:
      "#A39D93": "#000000"
  LS_Contour:
    expand: 1.5
    colours:
      "#A39D93": "#000000"
  TN_Watercourse:
    opacity: 1
  VSS_Watercourse:
    opacity: 1
  SS_Watercourse:
    opacity: 1
  MS_Hydroline:
    opacity: 1
  MS_Watercourse:
    opacity: 1
  LS_Hydroline:
    opacity: 1
  LS_Watercourse:
    opacity: 1
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
  
  class Map
    def initialize(config)
      @scale, @ppi = config.values_at("scale", "ppi")
      @resolution = @scale.to_f * 0.0254 / @ppi
      
      wgs84_points = case
      when config["zone"] && config["eastings"] && config["northings"]
        config.values_at("eastings", "northings").inject(:product).reproject("+proj=utm +zone=#{config["zone"]} +south +ellps=WGS84 +datum=WGS84 +units=m +no_defs", WGS84)
      when config["longitudes"] && config["latitudes"]
        config.values_at("longitudes", "latitudes").inject(:product)
      when config["size"] && config["zone"] && config["easting"] && config["northing"]
        [ config.values_at("easting", "northing").reproject("+proj=utm +zone=#{config["zone"]} +south +ellps=WGS84 +datum=WGS84 +units=m +no_defs", WGS84) ]
      when config["size"] && config["longitude"] && config["latitude"]
        [ config.values_at("longitude", "latitude") ]
      when config["bounds"] || File.exists?("bounds.kml")
        config["bounds"] ||= "bounds.kml"
        trackpoints = GPS.read_track(config["bounds"])
        waypoints = GPS.read_waypoints(config["bounds"])
        config["margin"] = 0 unless waypoints.any?
        trackpoints.any? ? trackpoints : waypoints.transpose.first
      else
        abort "Error: map extent must be provided as zone/eastings/northings, zone/easting/northing/size, latitudes/longitudes or latitude/longitude/size"
      end

      projection_centre = wgs84_points.transpose.map { |coords| 0.5 * (coords.max + coords.min) }
      @projection = "+proj=tmerc +lat_0=0.000000000 +lon_0=#{projection_centre.first} +k=0.999600 +x_0=500000.000 +y_0=10000000.000 +ellps=WGS84 +datum=WGS84 +units=m"
      @wkt = %Q{PROJCS["",GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.017453292519943295]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",500000.0],PARAMETER["False_Northing",10000000.0],PARAMETER["Central_Meridian",#{projection_centre.first}],PARAMETER["Scale_Factor",0.9996],PARAMETER["Latitude_Of_Origin",0.0],UNIT["Meter",1.0]]}
      # # zone = UTMGridService.zone(WGS84, projection_centre)
      # # projection = "+proj=utm +zone=#{zone} +south +ellps=WGS84 +datum=WGS84 +units=m +no_defs"
      # # # TODO: option to select a UTM projection instead of custom mercator (require declination rewrite)
      # proj_path = File.join(output_dir, "#{map_name}.prj")
      # File.open(proj_path, "w") { |file| file.puts projection }

      if config["size"]
        sizes = config["size"].split(/[x,]/).map(&:to_f)
        abort("Error: invalid map size: #{config["size"]}") unless sizes.length == 2 && sizes.all? { |size| size > 0.0 }
        @extents = sizes.map { |size| size * 0.001 * scale }
        @rotation = config["rotation"]
        abort("Error: cannot specify map size and auto-rotation together") if @rotation == "auto"
        abort "Error: map rotation must be between +/-45 degrees" unless @rotation.abs <= 45
        @centre = projection_centre.reproject(WGS84, @projection)
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
    end
    
    attr_reader :scale, :projection, :wkt, :bounds, :extents, :dimensions, :rotation, :ppi, :resolution
    
    def write_world_file(world_file_path)
      topleft = [ @centre, @extents.rotate_by(-@rotation * Math::PI / 180.0), [ :-, :+ ] ].transpose.map { |coord, extent, plus_minus| coord.send(plus_minus, 0.5 * extent) }
      WorldFile.write(topleft, @resolution, @rotation, world_file_path)
    end
  end
  
  InternetError = Class.new(Exception)
  ServerError = Class.new(Exception)
  BadGpxKmlFile = Class.new(Exception)
  BadLayerError = Class.new(Exception)
  
  module RetryOn
    def retry_on(*exceptions)
      intervals = [ 1, 2, 4, 8 ]
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
  
  module GPS # TODO: make into class?
    def self.read_waypoints(path)
      xml = REXML::Document.new(File.open path)
      case
      when xml.elements["/gpx"]
        xml.elements.collect("/gpx//wpt") do |element|
          [ [ element.attributes["lon"].to_f, element.attributes["lat"].to_f ], element.elements["name"].text ]
        end
      when xml.elements["/kml"]
        xml.elements.collect("/kml//Placemark") do |element|
          coords = element.elements["Point/coordinates"]
          name = element.elements["name"]
          coords && [ coords.text.split(',')[0..1].map(&:to_f), name ? name.text : "" ]
        end.compact
      else
        raise BadGpxKmlFile.new(path)
      end
    rescue REXML::ParseException
      raise BadGpxKmlFile.new(path)
    end

    def self.read_track(path)
      xml = REXML::Document.new(File.open path)
      case
      when xml.elements["/gpx"]
        xml.elements.collect("/gpx//trkpt") do |element|
          [ element.attributes["lon"].to_f, element.attributes["lat"].to_f ]
        end
      when xml.elements["/kml"]
        element = xml.elements["/kml//LineString/coordinates | /kml//Polygon//coordinates"]
        element ? element.text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) } : []
      else
        raise BadGpxKmlFile.new(path)
      end
    rescue REXML::ParseException
      raise BadGpxKmlFile.new(path)
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
  
  module SVG
    def self.make(map, &block)
      inches = map.extents.map { |extent| extent / 0.0254 / map.scale }
      # inches = bounds.map { |bound| (bound.max - bound.min) / 0.0254 / scale }
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
  end
  
  module RasterRenderer
    def render(label, options, map, output_dir)
      image = REXML::Element.new("image")
      image.add_attributes(
        "id" => label,
        "transform" => "scale(#{1.0 / map.ppi},#{1.0 / map.ppi})",
        "width" => map.dimensions[0],
        "height" => map.dimensions[1],
        "x" => 0,
        "y" => 0,
        "xlink:href" => "#{label}.png",
      )
      yield image
    end
  end
  
  class Service
    def initialize(params)
      @params = params
    end
  
    attr_reader :params
    
    def download(labels_options, map, output_dir)
      Dir.mktmpdir do |temp_dir|
        outstanding = labels_options.reject do |label, options|
          %w[png svg].any? { |ext| File.exist? File.join(output_dir, "#{label}.#{ext}") }
        end
        images(outstanding, map, temp_dir).each do |image_path|
          FileUtils.mv image_path, output_dir
        end unless outstanding.empty?
      end
    end
  end
  
  class OneToOneService < Service
    def images(labels_options, map, temp_dir)
      Enumerator.new do |yielder|
        labels_options.recover(InternetError, ServerError).each do |label, options|
          yielder << image(label, options, map, temp_dir)
        end
      end
    end
  end
  
  class TiledService < OneToOneService
    include RasterRenderer
    
    def image(label, options, map, temp_dir)
      puts "Downloading: #{label}"
      tile_paths = tiles(options, map, temp_dir).map do |tile_bounds, resolution, tile_path|
        topleft = [ tile_bounds.first.min, tile_bounds.last.max ]
        WorldFile.write(topleft, resolution, 0, "#{tile_path}w")
        %Q["#{tile_path}"]
      end
    
      puts "Assembling: #{label}"
      png_path = File.join(temp_dir, "#{label}.png")
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
      %x[convert -quiet "#{tif_path}" "#{png_path}"]
      
      png_path
    end
  end
  
  class TiledMapService < TiledService
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
  
  class LPIOrthoService < TiledService
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
  
  class ArcGIS < OneToOneService
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
      
      if params["cookie"] && !params["headers"]
        cookie = HTTP.head(URI.parse params["cookie"]) { |response| response["Set-Cookie"] }
        params["headers"] = { "Cookie" => cookie }
      end
      
      HTTP.get(export_uri(options, query), params["headers"]) do |response|
        block_given? ? yield(response.body) : response.body
      end
    end
  end
  
  class VectorArcGIS < ArcGIS
    def image(label, options, map, temp_dir)
      service = HTTP.get(service_uri(options, "f" => "json")) do |response|
        JSON.parse(response.body).tap do |result|
          raise ServerError.new(result["error"]["message"]) if result["error"]
        end
      end
      layer_order = service["layers"].reverse.map.with_index { |layer, index| { layer["name"] => index } }.inject({}, &:merge)
      layer_names = service["layers"].map { |layer| layer["name"] }
      
      resolution = options["resolution"] || map.resolution
      tile_list = tiles(map.bounds, resolution)
      
      w, h = dimensions(map.bounds, resolution)
      t = Math::tan(map.rotation * Math::PI / 180.0)
      d = (t * t - 1) * Math::sqrt(t * t + 1)
      if t >= 0
        y = (t * (h * t - w) / d).abs
        x = (t * y).abs
      else
        x = -(t * (h + w * t) / d).abs
        y = -(t * x).abs
      end
      offset_coeffs = [ x, -y ]
      rotate_coeffs = [ [ 1, 0 ], [ 0, 1 ] ].map { |vector| vector.rotate_by(map.rotation * Math::PI / 180.0) }
      inches_per_pixel = resolution / 0.0254 / map.scale
      coeffs = [ *rotate_coeffs, offset_coeffs ].flatten.map { |coeff| coeff * inches_per_pixel }
      transform = "matrix(#{coeffs.join ' '})"
      
      downloads = %w[layers labels].select do |type|
        options[type]
      end.map do |type|
        case options[type]
        when String, Array
          [ type, { map.scale => [ *options[type] ] } ]
        else
          [ type, options[type] ]
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
          end.merge("dpi" => scale * 0.0254 / resolution, "wkt" => map.wkt, "format" => "svg")
          xpath = type == "layers" ?
            "/svg//g[@id='#{service['mapName']}']//g[@id!='Labels' and not(.//g[@id])]" :
            "/svg//g[@id='#{service['mapName']}']/g[@id='Labels']"
          [ scale, layer_options, type, xpath ]
        end
      end.inject(:+)
          
      tilesets = tile_list.with_progress("Downloading: #{label}").map do |tile_bounds, tile_sizes, tile_offsets|
        tileset = downloads.map do |scale, layer_options, type, xpath|
          sleep params["interval"] if params["interval"]
          
          temp_dir = File.join(Dir.pwd, "tmp")
          temp_path = File.join temp_dir, [ type, scale, *tile_offsets, "svg" ].join(?.)
          
          ################################################################################
          tile_data = case
          when File.exists?(temp_path) then File.read(temp_path)
          else get_tile(tile_bounds, tile_sizes, options.merge(layer_options))
          end
          if Dir.exists?(temp_dir) && !File.exists?(temp_path)
            File.write temp_path, tile_data
          end
          
          tile_data.gsub! /ESRITransportation\&?Civic/, %Q['ESRI Transportation &amp; Civic']
          tile_data.gsub!  /ESRIEnvironmental\&?Icons/, %Q['ESRI Environmental &amp; Icons']
          
          [ /id="(\w+)"/, /url\(#(\w+)\)"/, /xlink:href="#(\w+)"/ ].each do |regex|
            tile_data.gsub! regex do |match|
              case $1
              when "Labels", service["mapName"], *layer_names then match
              else match.sub $1, [ label, type, scale, *tile_offsets, $1 ].join(?.)
              end
            end
          end
          
          [ REXML::Document.new(tile_data), scale, type, xpath ]
          ################################################################################
          # tile_xml = get_tile(tile_bounds, tile_sizes, options.merge(layer_options)) do |tile_data|
          #   tile_data.gsub! /ESRITransportation\&?Civic/, %Q['ESRI Transportation &amp; Civic']
          #   tile_data.gsub!  /ESRIEnvironmental\&?Icons/, %Q['ESRI Environmental &amp; Icons']
          # 
          #   [ /id="(\w+)"/, /url\(#(\w+)\)"/, /xlink:href="#(\w+)"/ ].each do |regex|
          #     tile_data.gsub! regex do |match|
          #       case $1
          #       when "Labels", service["mapName"], *layer_names then match
          #       else match.sub $1, [ label, type, scale, *tile_offsets, $1 ].join(?.)
          #       end
          #     end
          #   end
          #   
          #   begin
          #     REXML::Document.new(tile_data)
          #   rescue REXML::ParseException => e
          #     raise ServerError.new("Bad XML data received: #{e.message}")
          #   end
          # end
          # 
          # [ tile_xml, scale, type, xpath]
          ################################################################################
        end
        
        [ tileset, tile_sizes, tile_offsets ]
      end
      
      xml = SVG.make(map) do |svg|
        svg.add_element("defs") do |defs|
          tile_list.each do |tile_bounds, tile_sizes, tile_offsets|
            defs.add_element("clipPath", "id" => [ label, "tile", *tile_offsets ].join(?.)) do |clippath|
              clippath.add_element("rect", "width" => tile_sizes[0], "height" => tile_sizes[1])
            end
          end
        end
        
        layers = tilesets.find(lambda { [ [ ] ] }) do |tileset, _, _|
          tileset.all? { |tile_xml, _, _, xpath| tile_xml.elements[xpath] }
        end.first.map do |tile_xml, scale, type, xpath|
          tile_xml.elements.collect(xpath) do |layer|
            name = layer.attributes["id"]
            opacity = layer.parent.attributes["opacity"] || 1
            [ name, opacity ]
          end
        end.inject([], &:+).uniq(&:first).sort_by do |name, _, _|
          layer_order[name] || layer_order.length
        end.map do |name, opacity|
          { name => svg.add_element("g",
            "id" => [ label, name ].join(?.),
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
            
            tile_xml.elements.collect(xpath) do |layer|
              [ layer, layer.attributes["id"] ]
            end.select do |layer, id|
              layers[id]
            end.each do |layer, id|
              transform = "matrix(1 0 0 1 #{tile_offsets.join(' ')})"
              clip_path = "url(##{[ label, 'tile', *tile_offsets ].join(?.)})"
              layers[id].add_element("g", "transform" => transform, "clip-path" => clip_path) do |tile|
                layer.elements.each { |element| tile << element }
              end
            end
          end
        end
      end
      
      fonts = xml.elements.collect("//[@font-family]") { |element| element.attributes["font-family"] }.uniq
      if fonts.any?
        puts "Fonts required for #{label}.svg:"
        fonts.sort.each { |font| puts "  #{font}" }
      end
      
      mosaic_path = File.join(temp_dir, "#{label}.svg")
      File.open(mosaic_path, "w") { |file| xml.write file }
      
      mosaic_path
    rescue REXML::ParseException => e
      abort "Bad XML received:\n#{e.message}"
    end
    
    def rerender(xml, options)
      xml.elements.collect("/svg/g[@id]") do |layer|
        [ layer, layer.attributes["id"].split(?.).last ]
      end.select do |layer, id|
        options[id]
      end.each do |layer, id|
        xpaths = options[id].map do |command, values|
          case command
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
        end
        methods = options[id].map do |command, values|
          lambda do |attribute|
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
        [ xpaths, methods ].transpose.each do |xpath, method|
          [ *xpath ].each { |xp| REXML::XPath.each(layer, xp, &method) }
        end
      end
    end
    
    def render(label, options, map, output_dir, &block)
      svg = REXML::Document.new(File.read(File.join(output_dir, "#{label}.svg")))
      rerender(svg, options["render"] || {})
      svg.elements.each("/svg/defs", &block)
      svg.elements.each("/svg/g[@id]", &block)
    end
  end
  
  class RasterArcGIS < ArcGIS
    include RasterRenderer
    
    def image(label, options, map, temp_dir)
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
      
      mosaic_path = File.join(temp_dir, "#{label}.png")
      puts "Assembling: #{label}"
      
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
      
      mosaic_path
    end
  end

  class OneEarthDEMRelief < Service
    include RasterRenderer
    
    def images(labels_options, map, temp_dir)
      bounds = Bounds.transform(map.projection, WGS84, map.bounds)
      bounds = bounds.map { |bound| [ ((bound.first - 0.01) / 0.125).floor * 0.125, ((bound.last + 0.01) / 0.125).ceil * 0.125 ] }
      counts = bounds.map { |bound| ((bound.max - bound.min) / 0.125).ceil }
      units_per_pixel = 0.125 / 300
  
      puts "Downloading: #{labels_options.map(&:first).join ", "}"
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
      
      Enumerator.new do |yielder|
        labels_options.map do |label, options|
          puts "Calculating: #{label}"
          relief_path = File.join(temp_dir, "#{label}-small.tif")
          tif_path = File.join(temp_dir, "#{label}.tif")
          tfw_path = File.join(temp_dir, "#{label}.tfw")
          png_path = File.join(temp_dir, "#{label}.png")
          map.write_world_file(tfw_path)
          case options["name"]
          when "shaded-relief"
            altitude = params["altitude"]
            azimuth = params["azimuth"]
            exaggeration = params["exaggeration"]
            %x[convert -size #{map.dimensions.join ?x} -units PixelsPerInch -density #{map.ppi} canvas:black -type GrayScale -depth 8 "#{tif_path}"]
            %x[gdaldem hillshade -s 111120 -alt #{altitude} -z #{exaggeration} -az #{azimuth} "#{vrt_path}" "#{relief_path}" -q]
          when "color-relief"
            colours = { "0%" => "black", "100%" => "white" }
            colour_path = File.join(temp_dir, "colours.txt")
            File.open(colour_path, "w") do |file|
              colours.each { |elevation, colour| file.puts "#{elevation} #{colour}" }
            end
            %x[convert -size #{map.dimensions.join ?x} -units PixelsPerInch -density #{map.ppi} canvas:black -type TrueColor -depth 8 "#{tif_path}"]
            %x[gdaldem color-relief "#{vrt_path}" "#{colour_path}" "#{relief_path}" -q]
          end
          %x[gdalwarp -s_srs "#{WGS84}" -t_srs "#{map.projection}" -r bilinear "#{relief_path}" "#{tif_path}"]
          %x[convert "#{tif_path}" -quiet -type TrueColor -depth 8 "#{png_path}"]
        
          yielder << png_path
        end
      end
    end
  end

  # class UTMGridService < Service
  #   def self.zone(projection, coords)
  #     (coords.reproject(projection, WGS84).first / 6).floor + 31
  #   end
  # 
  #   def initialize(*args)
  #     super(*args)
  #     @zone = params["zone"]
  #     @projection = "+proj=utm +zone=#{zone} +south +ellps=WGS84 +datum=WGS84 +units=m +no_defs"
  #   end
  # 
  #   attr_reader :zone
  # 
  #   def zone_contains?(coords)
  #     UTMGridService.zone(projection, coords) == zone
  #   end
  # 
  #   def pixel_for(coords, bounds, scaling)
  #     [ coords, bounds, [ 1, -1 ] ].transpose.map.with_index do |(coord, bound, sign), index|
  #       ((coord - bound[index]) * sign / scaling.metres_per_pixel).round
  #     end
  #   end
  #   
  #   def images(labels_options, input_bounds, input_projection, scaling, rotation, dimensions, centre, temp_dir, world_file_path)
  #     return [].each unless input_bounds.inject(:product).map { |corner| UTMGridService.zone(input_projection, corner) }.include? zone
  #     
  #     bounds = Bounds.transform(input_projection, projection, input_bounds)
  #     Enumerator.new do |yielder|
  #       labels_options.map do |label, options|
  #         puts "Creating: #{label}"
  #         interval, fontsize, family, weight = params.values_at("interval", "fontsize", "family", "weight")
  # 
  #         tick_indices = bounds.map do |bound|
  #           ((bound.first / interval).floor .. (bound.last / interval).ceil).to_a
  #         end
  #         tick_coords = tick_indices.map { |indices| indices.map { |index| index * interval } }
  #         centre_coords = bounds.map { |bound| 0.5 * bound.inject(:+) }
  #         centre_indices = [ centre_coords, tick_indices ].transpose.map do |coord, indices|
  #           indices.index((coord / interval).round)
  #         end
  # 
  #         draw_string = case options["name"]
  #         when "grid"
  #           string = [ :to_a, :reverse ].map do |order|
  #             tick_coords.send(order).first.map do |perpendicular_coord|
  #               line_coords = tick_coords.send(order).last.map do |parallel_coord|
  #                 [ perpendicular_coord, parallel_coord ].send(order)
  #               end.select { |coords| zone_contains? coords }
  #               line_coords.length > 1 ? [ line_coords.first, line_coords.last ] : nil
  #             end.compact
  #           end.inject(:+).map do |end_coords|
  #             end_coords.map { |coords| pixel_for coords, bounds, scaling }
  #           end.map do |end_pixels|
  #             %Q[-draw "line #{end_pixels.first.first},#{end_pixels.first.last} #{end_pixels.last.first},#{end_pixels.last.last}"]
  #           end.join " "
  #           "-stroke white -strokewidth 1 #{string}"
  #         when "eastings", "northings"
  #           eastings = options["name"] == "eastings"
  #           index = eastings ? 0 : 1
  #           angle = eastings ? 90 : 0
  #           label_spacing = params["labels"]["spacing"]
  #           divisor = interval % 1000 == 0 ? 1000 : 1
  #           square = (interval / scaling.metres_per_pixel).round
  #           margin = (0.04 * scaling.ppi).ceil
  #           label_coords = tick_coords[index].select do |coord|
  #             coord % (label_spacing * interval) == 0
  #           end.map do |coord|
  #             case params["labels"]["style"]
  #             when "line"
  #               [ [ coord, tick_coords[1-index][centre_indices[1-index]] ].send(index.zero? ? :to_a : :reverse) ]
  #             when "grid"
  #               tick_coords[1-index].select do |perp_coord|
  #                 perp_coord % (label_spacing * interval) == 0
  #               end.map do |perp_coord|
  #                 [ coord, perp_coord + 0.5 * interval ].send(index.zero? ? :to_a : :reverse)
  #               end
  #             end
  #           end.inject(:+) || []
  #           string = label_coords.select do |coords|
  #             zone_contains? coords
  #           end.map do |coords|
  #             [ pixel_for(coords, bounds, scaling), coords[index] ]
  #           end.map do |pixel, coord|
  #             grid_reference = (coord / divisor).to_i
  #             case params["labels"]["style"]
  #             when "grid"
  #               %Q[#{OP} -pointsize #{fontsize} -family "#{family}" -weight #{weight} -size #{square}x#{square} canvas:none -gravity Center -annotate "#{angle}" "#{grid_reference}" -repage %+i%+i #{CP} -layers flatten] % pixel.map { |p| p - square / 2 }
  #             when "line"
  #               %Q[-draw "translate #{pixel.join ?,} rotate #{angle} text #{margin},#{-margin} '#{grid_reference}'"]
  #             end
  #           end.join " "
  #           %Q[-background none -fill white -pointsize #{fontsize} -family "#{family}" -weight #{weight} #{string}]
  #         end
  #     
  #         canvas_dimensions = bounds.map { |bound| ((bound.max - bound.min) / scaling.metres_per_pixel).ceil }
  #         canvas_path = File.join(temp_dir, "canvas.tif")
  #         result_path = File.join(temp_dir, "result.tif")
  #         canvas_tfw_path = File.join(temp_dir, "canvas.tfw")
  #         result_tfw_path = File.join(temp_dir, "result.tfw")
  #         png_path = File.join(temp_dir, "#{label}.png")
  #     
  #         %x[convert -size #{canvas_dimensions.join ?x} -units PixelsPerInch -density #{scaling.ppi} canvas:black -type TrueColor -depth 8 #{draw_string} "#{canvas_path}"]
  #         WorldFile.write([ bounds.first.first, bounds.last.last ], scaling.metres_per_pixel, 0, canvas_tfw_path)
  #         %x[convert -size #{dimensions.join ?x} -units PixelsPerInch -density #{scaling.ppi} canvas:black -type TrueColor -depth 8 "#{result_path}"]
  #         FileUtils.cp(world_file_path, result_tfw_path)
  #         resample = params["resample"] || "cubic"
  #         %x[gdalwarp -s_srs "#{projection}" -t_srs "#{input_projection}" -r #{resample} "#{canvas_path}" "#{result_path}"]
  #         %x[convert -quiet "#{result_path}" "#{png_path}"]
  #       
  #         yielder << png_path
  #       end
  #     end
  #   end
  # end
  
  # class AnnotationService < OneToOneService
  #   def image(label, options, input_bounds, input_projection, scaling, rotation, dimensions, centre, temp_dir, world_file_path)
  #     puts "Creating: #{label}"
  #     png_path = File.join(temp_dir, "#{label}.png")
  #     draw_string = draw(input_projection, scaling, rotation, dimensions, centre, options)
  #     %x[convert -size #{dimensions.join ?x} -units PixelsPerInch -density #{scaling.ppi} canvas:black #{draw_string} -type TrueColor -depth 8 "#{png_path}"]
  #     
  #     png_path
  #   end
  # end
  # 
  # class DeclinationService < AnnotationService
  #   def self.get_declination(coords, projection)
  #     degrees_minutes_seconds = coords.reproject(projection, WGS84).map do |coord|
  #       [ (coord > 0 ? 1 : -1) * coord.abs.floor, (coord.abs * 60).floor % 60, (coord.abs * 3600).round % 60 ]
  #     end
  #     today = Date.today
  #     year_month_day = [ today.year, today.month, today.day ]
  #     url = "http://www.ga.gov.au/bin/geoAGRF?latd=%i&latm=%i&lats=%i&lond=%i&lonm=%i&lons=%i&elev=0&year=%i&month=%i&day=%i&Ein=D" % (degrees_minutes_seconds.reverse.flatten + year_month_day)
  #     HTTP.get(URI.parse url) do |response|
  #       /D\s*=\s*(\d+\.\d+)/.match(response.body) { |match| match.captures[0].to_f }
  #     end
  #   end
  # 
  #   # TODO: won't work unless projection is true-north-aligned
  #   def draw(input_projection, scaling, rotation, dimensions, centre, options)
  #     spacing = params["spacing"]
  #     declination = params["angle"] || DeclinationService.get_declination(centre, input_projection)
  #     angle = declination + rotation
  #     x_spacing = spacing / Math::cos(angle * Math::PI / 180.0) / scaling.metres_per_pixel
  #     dx = dimensions.last * Math::tan(angle * Math::PI / 180.0)
  #     x_min = [ 0, dx ].min
  #     x_max = [ dimensions.first, dimensions.first + dx ].max
  #     line_count = ((x_max - x_min) / x_spacing).ceil
  #   
  #     string = (1..line_count).map do |n|
  #       x_min + n * x_spacing
  #     end.map do |x|
  #        %Q[-draw "line #{x.round},0 #{(x - dx).round},#{dimensions.last}"]
  #     end.join " "
  #   
  #     %Q[-fill black -draw "color 0,0 reset" -stroke white -strokewidth 1 #{string}]
  #   end
  # end
  # 
  # class ControlService < AnnotationService
  #   def get(*args, &block)
  #     super(*args, &block) if params["file"]
  #   end
  # 
  #   def draw(input_projection, scaling, rotation, dimensions, centre, options)
  #     waypoints, names = GPS.read_waypoints(params["file"]).select do |waypoint, name|
  #       case options["name"]
  #       when /control/ then name[/\d{2,3}|HH/]
  #       when /waterdrop/ then name[/W/]
  #       end
  #     end.transpose
  #     return "" unless waypoints
  #   
  #     radius = params["diameter"] * scaling.ppi / 25.4 / 2
  #     strokewidth = params["thickness"] * scaling.ppi / 25.4
  #     family = params["family"]
  #     fontsize = options["name"] == "waterdrops" ? params["waterdrop-size"] * 3.7 : params["fontsize"]
  #     weight = params["weight"]
  #     cx, cy = dimensions.map { |dimension| 0.5 * dimension }
  #   
  #     string = [ waypoints.reproject(WGS84, input_projection), names ].transpose.map do |coords, name|
  #       offsets = [ coords, centre, [ 1, -1 ] ].transpose.map { |coord, cent, sign| (coord - cent) * sign / scaling.metres_per_pixel }
  #       x, y = offsets.rotate_by(rotation * Math::PI / 180.0)
  #       case options["name"]
  #       when "control-circles"
  #         case name
  #         when /HH/ then %Q[-draw "polygon #{cx + x},#{cy + y - radius} #{cx + x + radius * Math::sqrt(0.75)},#{cy + y + radius * 0.5}, #{cx + x - radius * Math::sqrt(0.75)},#{cy + y + radius * 0.5}"]
  #         else %Q[-draw "circle #{cx + x},#{cy + y} #{cx + x + radius},#{cy + y}"]
  #         end
  #       when "control-labels"
  #         %Q[-draw "text #{cx + x + radius},#{cy + y - radius} '#{name[/\d{2,3}|HH/]}'"]
  #       when "waterdrops"
  #         %Q[-draw "gravity Center text #{x},#{y} 'S'"]
  #       end
  #     end.join " "
  #   
  #     case options["name"]
  #     when "control-circles"
  #       %Q[-fill black -draw "color 0,0 reset" -stroke white -strokewidth #{strokewidth} #{string}]
  #     when "control-labels"
  #       %Q[-fill black -draw "color 0,0 reset" -fill white -pointsize #{fontsize} -weight #{weight} -family "#{family}" #{string}]
  #     when "waterdrops"
  #       %Q[-fill black -draw "color 0,0 reset" -stroke white -strokewidth #{strokewidth} -pointsize #{fontsize} -family Wingdings #{string}]
  #     end
  #   rescue BadGpxKmlFile => e
  #     raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
  #   end
  # end
  # 
  # class OverlayService < OneToOneService
  #   # def get(labels_options, input_bounds, input_projection, scaling, rotation, dimensions, centre, output_dir, world_file_path)
  #   def image(label, options, input_bounds, input_projection, scaling, rotation, dimensions, centre, temp_dir, world_file_path)
  #     puts "Creating: #{label}"
  #     kml_path = options["path"]
  #     tif_path = File.join(temp_dir, "#{label}.tif")
  #     tfw_path = File.join(temp_dir, "#{label}.tfw")
  #     png_path = File.join(temp_dir, "#{label}.png")
  #     gml_path = File.join(temp_dir, "#{label}.gml")
  #     output_path = File.join(output_dir, "#{label}.png")
  #     %x[convert -size #{dimensions.join ?x} -units PixelsPerInch -density #{scaling.ppi} canvas:black "#{tif_path}"]
  #     FileUtils.cp(world_file_path, tfw_path)
  #     %x[ogr2ogr -t_srs "#{input_projection}" -f "GML" "#{gml_path}" "#{kml_path}"]
  #     %x[ogrinfo -q "#{gml_path}"].scan(/^\d+: ([^\(\n]*)/).flatten.each do |layername|
  #       %x[gdal_rasterize -l "#{layername.strip}" -burn 255 "#{gml_path}" "#{tif_path}"]
  #     end
  #     sequence = options["thickness"] && options["thickness"] > 0 ? "-morphology Dilate Disk:%.1f" % (0.5 * options["thickness"] * scaling.ppi / 25.4) : ""
  #     %x[convert -quiet "#{tif_path}" #{sequence} "#{png_path}"]
  #     
  #     png_path
  #   end
  # end
  
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
    output_dir = Dir.pwd
    default_config = YAML.load(CONFIG)
    default_config["controls"]["file"] ||= "controls.gpx" if File.exists?(File.join(output_dir, "controls.gpx"))
    user_config = begin
      YAML.load File.open(File.join(output_dir, "config.yml"))
    rescue ArgumentError, SyntaxError => e
      abort "Error in configuration file: #{e.message}"
    end
    config = default_config.deep_merge user_config
    config["exclude"] = [ *config["exclude"] ]
    config["formats"].each(&:downcase!)
    {
      "utm" => /utm-.*/,
      "aerial" => /aerial-.*/,
      "aerial-lpi" => /aerial-lpi-.*/,
      "relief" => /elevation|shaded-relief/
    }.each do |shortcut, regex|
      config["exclude"] << regex if config["exclude"].delete(shortcut)
    end
    config["rotation"] = -(config["declination"]["angle"] || DeclinationService.get_declination(projection_centre, WGS84)) if config["rotation"] == "magnetic"
    
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
    )
    # atlas = ArcGIS.new(
    #   "host" => "atlas.nsw.gov.au",
    #   "instance" => "ArcGis1",
    #   "cookie" => "http://atlas.nsw.gov.au/",
    #   "tile_sizes" => [ 2048, 2048 ],
    #   "interval" => 0.1,
    # )
    # declination_service = DeclinationService.new(config["declination"])
    # control_service = ControlService.new(config["controls"])
    lpi_ortho = LPIOrthoService.new(
      "host" => "lite.maps.nsw.gov.au",
      "tile_size" => 1024,
      "interval" => 1.0,
      "projection" => "EPSG:3308",
    )
    nokia_maps = TiledMapService.new(
      "uri" => "http://m.ovi.me/?c=${latitude},${longitude}&t=${name}&z=${zoom}&h=${vsize}&w=${hsize}&f=${format}&nord&nodot",
      "projection" => "EPSG:3857",
      "tile_sizes" => [ 1024, 1024 ],
      "interval" => 1.2,
      "crops" => [ [ 0, 0 ], [ 26, 0 ] ],
      "tile_limit" => 250,
      "retries_on_blank" => 1,
    )
    google_maps = TiledMapService.new(
      "uri" => "http://maps.googleapis.com/maps/api/staticmap?zoom=${zoom}&size=${hsize}x${vsize}&scale=1&format=${format}&maptype=${name}&sensor=false&center=${latitude},${longitude}",
      "projection" => "EPSG:3857",
      "tile_sizes" => [ 640, 640 ],
      "interval" => 1.2,
      "crops" => [ [ 0, 0 ], [ 30, 0 ] ],
      "tile_limit" => 250,
    )
    oneearth_relief = OneEarthDEMRelief.new({ "interval" => 0.3 }.merge config["relief"])

    services = {
      sixmaps_vector => {
        "topographic" => {
          "service" => "LPIMap",
          "resolution" => 0.55,
          "layers" => {
            4500 => {
              "LS_Roads_onbridge" => %q["functionhierarchy" = 9 AND "classsubtype" = 6 AND NOT "roadontype" IN (1,3)],
              "LS_Roads_onground" => %q["functionhierarchy" = 9 AND "classsubtype" = 6 AND "roadontype" = 1],
            },
            9000 => %w[LS_PlacePoint LS_GeneralCulturalPoint PointOfInterest DLSPoint DLSLine MS_BuildingComplexPoint GeneralCulturalPoint MS_RoadNameExtent_Labels MS_Roads_Labels TransportFacilityPoint MS_Railway MS_Roads MS_LocalRoads MS_Tracks_onground MS_Roads_intunnel AncillaryHydroPoint AncillaryHydroPoint_Bore TransportFacilityLine GeneralCulturalLine DLSArea_overwater FuzzyExtentLine Runway VSS_Oceans HydroArea LS_Watercourse LS_Hydroline MS_Watercourse MS_Hydroline DLSArea_underwater SS_Watercourse VSS_Watercourse TN_Watercourse border Rural_Property Lot LS_Contour GeneralCulturalArea Urban_Areas],
          },
          "labels" => {
            12000 => %w[LS_PlacePoint LS_GeneralCulturalPoint PointOfInterest DLSPoint DLSLine MS_BuildingComplexPoint GeneralCulturalPoint MS_RoadNameExtent_Labels MS_Roads_Labels TransportFacilityPoint MS_Railway MS_Roads MS_LocalRoads MS_Tracks_onground MS_Roads_intunnel AncillaryHydroPoint AncillaryHydroPoint_Bore TransportFacilityLine GeneralCulturalLine DLSArea_overwater FuzzyExtentLine Runway VSS_Oceans HydroArea LS_Watercourse LS_Hydroline MS_Watercourse MS_Hydroline DLSArea_underwater SS_Watercourse VSS_Watercourse TN_Watercourse border Rural_Property MS_Contour Urban_Areas],
            # GeneralCulturalArea # TODO: labels?
          },
          "render" => {
            "LS_Roads_onground" => { "expand" => 2, "colours" => { "#A39D93" => "#000000" } },
            "LS_Roads_onbridge" => { "expand" => 2, "colours" => { "#A39D93" => "#000000" } },
            "LS_Contour" =>        { "expand" => 1.5 },
            "TN_Watercourse" =>    { "opacity" => 1 },
            "VSS_Watercourse" =>   { "opacity" => 1 },
            "SS_Watercourse" =>    { "opacity" => 1 },
            "MS_Hydroline" =>      { "opacity" => 1 },
            "MS_Watercourse" =>    { "opacity" => 1 },
            "LS_Hydroline" =>      { "opacity" => 1 },
            "LS_Watercourse" =>    { "opacity" => 1 },
          },
        },
        # "holdings" => {
        #   "service" => "LHPA",
        #   "layers" => %w[Holdings],
        #   "labels" => %w[Holdings],
        # },
      },
      sixmaps_raster => {
        "nsw-topo" => {
          "service" => "NSWTopo",
          "image" => true,
        },
        "aerial-webm" => {
          "service" => "Best_WebM",
          "image" => true,
        },
      },
      # declination_service => {
      #   "declination" => { }
      # },
      # control_service => {
      #   "control-labels" => { "name" => "control-labels" },
      #   "control-circles" => { "name" => "control-circles" },
      #   "waterdrops" => { "name" => "waterdrops" },
      # },
      lpi_ortho => {
        "aerial-lpi-ads40" => { "config" => "/ADS40ImagesConfig.js" },
        # "aerial-lpi-sydney" => { "config" => "/SydneyImagesConfig.js" },
        # "aerial-lpi-towns" => { "config" => "/NSWRegionalCentresConfig.js" },
        "aerial-lpi-eastcoast" => { "image" => "/Imagery/lr94ortho1m.ecw" },
        "reference-topo" => { "image" => "/OTDF_Imagery/NSWTopoS2v2.ecw", "otdf" => true }
      },
      google_maps => {
        "aerial-google" => { "name" => "satellite", "format" => "jpg" }
      },
      nokia_maps => {
        "aerial-nokia" => { "name" => 1, "format" => 1 }
      },
      oneearth_relief => {
        "shaded-relief" => { "name" => "shaded-relief" },
        "elevation" => { "name" => "color-relief" },
      },
    }

    # [ 54, 55, 56 ].each do |zone|
    #   grid_service = UTMGridService.new({ "zone" => zone }.merge config["grid"])
    #   services.merge!(grid_service => {
    #     "utm-#{zone}-grid" => { "name" => "grid" },
    #     "utm-#{zone}-eastings" => { "name" => "eastings" },
    #     "utm-#{zone}-northings" => { "name" => "northings" }
    #   })
    # end
    # 
    # overlays = [ *config["overlays"] ].inject({}) do |hash, (filename_or_path, thickness)|
    #   hash.merge(File.split(filename_or_path).last.partition(/\.\w+$/).first => { "path" => filename_or_path, "thickness" => thickness })
    # end
    # services.merge!(OverlayService.new({}) => overlays)
    # overlay_labels = overlays.keys

    puts "Map details:"
    puts "  size: %imm x %imm" % map.extents.map { |extent| 1000 * extent / map.scale }
    puts "  scale: 1:%i" % map.scale
    puts "  rotation: %.1f degrees" % map.rotation
    puts "  %.1f megapixels (%i x %i) @ %i ppi" % [ 0.000001 * map.dimensions.inject(:*), *map.dimensions, map.ppi ]
    
    [ *services.values, config["compose"] ].each do |label_list|
      label_list.reject! do |label|
        config["exclude"].any? do |matcher|
          matcher.is_a?(String) ? label == matcher : label =~ matcher
        end
      end
    end
    
    services.each do |service, labels_options|
      service.download(labels_options, map, output_dir) unless labels_options.empty?
    end
    
    output_path = File.join output_dir, "#{config['name']}.svg"
    File.open(output_path, "w") do |file|
      SVG.make(map) do |svg|
        config["compose"].each do |label|
          service = services.find do |_, labels_options|
            labels_options[label]
          end.first
          options = services[service][label]
          svg.add_element("g", "id" => label) do |group|
            service.render(label, options, map, output_dir) do |element|
              group.elements << element
            end
          end
        end
      end.write(file)
    end
    
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

# TODO: put long command lines into text file...
# TODO: allow user to select between UTM projection and north-aligned projection
# TODO: reinstate rotation

# TODO: add rasters as layers
# TODO: inline clip rects?
# TODO: check tile scalings to avoid polygon area tile boundary lines
# TODO: option to allow for tiles not to be clipped (e.g. for labels)?
# TODO: workflow
# TODO: colouring, expanding, stretching etc.
# TODO: decide which layers and scales to use
# TODO: label sizing
# TODO: handle case where only image data is returned in a vector request
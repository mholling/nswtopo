#!/usr/bin/env ruby

# Copyright 2011 Matthew Hollingworth
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

Signal.trap("INT") do
  puts
  puts "Halting execution. Run the script again to resume map creation."
  exit
end

EARTH_RADIUS = 6378137.0
WGS84 = "EPSG:4326"

WINDOWS = !RbConfig::CONFIG["host_os"][/mswin|mingw/].nil?
OP = WINDOWS ? '(' : '\('
CP = WINDOWS ? ')' : '\)'

class REXML::Element
  alias_method :unadorned_add_element, :add_element
  def add_element(name, attrs = {})
    result = unadorned_add_element(name, attrs)
    yield result if block_given?
    result
  end
end

class Hash
  def deep_merge(hash)
    hash.inject(self.dup) do |result, (key, value)|
      result.merge(key => result[key].is_a?(Hash) && value.is_a?(Hash) ? result[key].deep_merge(value) : value)
    end
  end
  
  def to_query
    map { |key, value| "#{key}=#{value}" }.join("&")
  end
end

class Array
  def with_progress(symbol = ?-, container = "    [%s]", bars = 70)
    divider = (length - 1) / 40 + 1
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
  
  def rotate(angle)
    cos = Math::cos(angle)
    sin = Math::sin(angle)
    [ self[0] * cos - self[1] * sin, self[0] * sin + self[1] * cos ]
  end
  
  def rotate!(angle)
    self[0], self[1] = rotate(angle)
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
    else %x[echo #{join(' ')} | gdaltransform -s_srs "#{source_projection}" -t_srs "#{target_projection}"].split(" ")[0..1].map { |number| number.to_f }
    end
  end
end

def convex_hull(points)
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

def minimum_bounding_box(points)
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
    
    calipers.each { |caliper| caliper.rotate!(angle) }
    rotation += angle
    
    break if rotation >= Math::PI / 2
    
    dimensions = [ 0, 1 ].map do |offset|
      polygon[indices[offset + 2]].minus(polygon[indices[offset]]).proj(calipers[offset + 1])
    end
    
    centre = polygon.values_at(*indices).map do |point|
      point.rotate(-rotation)
    end.partition.with_index do |point, index|
      index.even?
    end.map.with_index do |pair, index|
      0.5 * pair.map { |point| point[index] }.inject(:+)
    end.rotate(rotation)
    
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

InternetError = Class.new(Exception)
BadLayer = Class.new(Exception)
BadGpxKmlFile = Class.new(Exception)

def http_request(uri, req, options)
  retries = options["retries"] || 0
  begin
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
    case response
    when Net::HTTPSuccess then return yield response
    else response.error!
    end
  rescue Timeout::Error, Errno::ETIMEDOUT, Errno::EINVAL, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError => e
    if retries > 0
      retries -= 1 and retry
    else
      raise InternetError.new(e.message)
    end
  end
end

def http_get(uri, options = {}, &block)
  http_request uri, Net::HTTP::Get.new(uri.request_uri), options, &block
end

def http_post(uri, body, options = {}, &block)
  req = Net::HTTP::Post.new(uri.request_uri)
  req.body = body.to_s
  http_request uri, req, options, &block
end

def transform_bounds(source_projection, target_projection, bounds)
  bounds.inject(:product).reproject(source_projection, target_projection).transpose.map { |coords| [ coords.min, coords.max ] }
end

def bounds_intersect?(bounds1, bounds2)
  [ bounds1, bounds2 ].transpose.map do |bound1, bound2|
    bound1.max > bound2.min && bound1.min < bound2.max
  end.inject(:&)
end

def write_world_file(topleft, resolution, angle, path)
  File.open(path, "w") do |file|
    file.puts  resolution * Math::cos(angle * Math::PI / 180.0)
    file.puts  resolution * Math::sin(angle * Math::PI / 180.0)
    file.puts  resolution * Math::sin(angle * Math::PI / 180.0)
    file.puts -resolution * Math::cos(angle * Math::PI / 180.0)
    file.puts topleft.first + 0.5 * resolution
    file.puts topleft.last - 0.5 * resolution
  end
end

def read_waypoints(path)
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
      coords && [ coords.text.split(',')[0..1].map { |coord| coord.to_f }, name ? name.text : "" ]
    end.compact
  else
    raise BadGpxKmlFile.new(path)
  end
rescue REXML::ParseException
  raise BadGpxKmlFile.new(path)
end

def read_track(path)
  xml = REXML::Document.new(File.open path)
  case
  when xml.elements["/gpx"]
    xml.elements.collect("/gpx//trkpt") do |element|
      [ element.attributes["lon"].to_f, element.attributes["lat"].to_f ]
    end
  when xml.elements["/kml"]
    element = xml.elements["/kml//LineString/coordinates | /kml//Polygon//coordinates"]
    element ? element.text.split(' ').map { |triplet| triplet.split(',')[0..1].map { |coord| coord.to_f } } : []
  else
    raise BadGpxKmlFile.new(path)
  end
rescue REXML::ParseException
  raise BadGpxKmlFile.new(path)
end

class Scaling
  def initialize(scale, ppi)
    @ppi = ppi
    @scale = scale
    @metres_per_pixel = scale * 0.0254 / ppi
  end
  
  attr_reader :ppi, :scale, :metres_per_pixel
end

class Service
  def initialize(params)
    @params = params
    @projection = params["projection"]
  end
  
  attr_reader :projection, :params
end

class ArcIMS < Service
  def tiles(tile_sizes, input_bounds, input_projection, scaling)
    bounds = transform_bounds(input_projection, projection, input_bounds)
    extents = bounds.map { |bound| bound.max - bound.min }
    pixels = extents.map { |extent| (extent / scaling.metres_per_pixel).ceil }
    counts = [ pixels, tile_sizes ].transpose.map { |pixel, tile_size| (pixel - 1) / tile_size + 1 }
    origins = [ bounds.first.min, bounds.last.max ]
    
    tile_extents = [ counts, tile_sizes, pixels ].transpose.map do |count, dimension, pixel|
      [ dimension ] * (count - 1) << (((pixel - 1) % dimension) + 1)
    end
    
    tile_bounds = [ tile_extents, origins, [ :+, :- ] ].transpose.map do |extents, origin, increment|
      boundaries = extents.inject([0]) do |memo, extent|
        memo << memo.last + extent
      end.map do |pixels|
        origin.send(increment, pixels * scaling.metres_per_pixel)
      end
      [ boundaries[0..-2], boundaries[1..-1] ].transpose.map { |bounds| bounds.sort }
    end
    
    [ tile_bounds.inject(:product), tile_extents.inject(:product) ].transpose
  end
  
  def dataset(input_bounds, input_projection, scaling, label, options_or_array, dir)
    projected_bounds = transform_bounds(input_projection, params["envelope"]["projection"], input_bounds)
    return nil unless bounds_intersect?(projected_bounds, params["envelope"]["bounds"])
    
    options_array = [ options_or_array ].flatten
    
    margin = options_array.any? { |options| options["text"] } ? 0 : (1.27 * scaling.ppi / 25.4).ceil
    cropped_tile_sizes = params["tile_sizes"].map { |tile_size| tile_size - 2 * margin }
    
    scales = options_array.map { |options| options["scale"] }.compact.uniq
    abort("more than one scale specified") if scales.length > 1
    dpi = scales.any? ? (scales.first * scaling.ppi).round : params["dpi"]
    
    puts "Layer: #{label}"
    puts "  downloading..."
    tiles(cropped_tile_sizes, input_bounds, input_projection, scaling).with_progress.with_index.map do |(cropped_bounds, cropped_extents), tile_index|
      extents = cropped_extents.map { |cropped_extent| cropped_extent + 2 * margin }
      bounds = cropped_bounds.map do |cropped_bound|
        [ cropped_bound, [ :-, :+ ] ].transpose.map { |coord, increment| coord.send(increment, margin * scaling.metres_per_pixel) }
      end
      
      tile_path = File.join(dir, "tile.#{tile_index}.png")
      
      xml = REXML::Document.new
      xml << REXML::XMLDecl.new(1.0, "UTF-8")
      xml.add_element("ARCXML", "version" => 1.1) do |arcxml|
        arcxml.add_element("REQUEST") do |request|
          request.add_element("GET_IMAGE") do |get_image|
            get_image.add_element("PROPERTIES") do |properties|
              properties.add_element("FEATURECOORDSYS", "string" => params["wkt"])
              properties.add_element("FILTERCOORDSYS", "string" => params["wkt"])
              properties.add_element("ENVELOPE", "minx" => bounds.first.first, "maxx" => bounds.first.last, "miny" => bounds.last.first, "maxy" => bounds.last.last)
              properties.add_element("IMAGESIZE", "width" => extents.first, "height" => extents.last, "dpi" => dpi, "scalesymbols" => true)
              properties.add_element("BACKGROUND", "color" => "0,0,0")
              properties.add_element("OUTPUT", "format" => "png")
              properties.add_element("LAYERLIST", "nodefault" => true) do |layerlist|
                options_array.each_with_index do |options, layer_index|
                  layerlist.add_element("LAYERDEF", "id" => options["image"] || "custom#{layer_index}", "visible" => true)
                end
              end
            end
            options_array.each_with_index do |options, layer_index|
              unless options["image"]
                get_image.add_element("LAYER", "type" => options["image"] ? "image" : "featureclass", "visible" => true, "id" => "custom#{layer_index}") do |layer|
                  layer.add_element("DATASET", "fromlayer" => options["from"])
                  layer.add_element("SPATIALQUERY", "where" => options["where"]) if options["where"]
                  renderer_type = "#{options["lookup"] ? 'VALUEMAP' : 'SIMPLE'}#{'LABEL' if options["label"]}RENDERER"
                  renderer_attributes = {}
                  renderer_attributes.merge! (options["lookup"] ? "labelfield" : "field") => options["label"]["field"] if options["label"]
                  renderer_attributes.merge! options["label"].reject { |k, v| k == "field" || (k == "rotationalangles" && v.zero?) } if options["label"]
                  renderer_attributes.merge! "lookupfield" => options["lookup"] if options["lookup"]
                  layer.add_element(renderer_type, renderer_attributes) do |renderer|
                    content = lambda do |parent, type, attributes|
                      case type
                      when "line"
                        attrs = { "color" => "255,255,255", "antialiasing" => true }.merge(attributes)
                        parent.add_element("SIMPLELINESYMBOL", attrs)
                      when "hashline"
                        attrs = { "color" => "255,255,255", "antialiasing" => true }.merge(attributes)
                        parent.add_element("HASHLINESYMBOL", attrs)
                      when "marker"
                        attrs = { "color" => "255,255,255", "outline" => "0,0,0" }.merge(attributes)
                        attrs["width"] = (attrs["width"] / 25.4 * scaling.ppi).round
                        parent.add_element("SIMPLEMARKERSYMBOL", attrs)
                      when "polygon"
                        attrs = { "fillcolor" => "255,255,255", "boundarycolor" => "255,255,255" }.merge(attributes)
                        parent.add_element("SIMPLEPOLYGONSYMBOL", attrs)
                      when "text"
                        attrs = { "fontcolor" => "255,255,255", "antialiasing" => true, "interval" => 0 }.merge(attributes)
                        attrs["fontsize"] = (attrs["fontsize"] * scaling.ppi / 72.0).round
                        attrs["interval"] = (attrs["interval"] / 25.4 * scaling.ppi).round
                        parent.add_element("TEXTSYMBOL", attrs)
                      when "truetypemarker"
                        attrs = { "fontcolor" => "255,255,255", "outline" => "0,0,0", "antialiasing" => true }.merge(attributes)
                        attrs["fontsize"] = (attrs["fontsize"] * scaling.ppi / 72.0).round
                        parent.add_element("TRUETYPEMARKERSYMBOL", attrs)
                      end
                    end
                    [ "line", "hashline", "marker", "polygon", "text", "truetypemarker" ].each do |type|
                      if options[type]
                        if options["lookup"]
                          options[type].each do |value, attributes|
                            tag, tag_attributes = case value
                            when Range
                              [ "RANGE", { "lower" => value.min, "upper" => value.max } ]
                            when nil
                              [ "OTHER", { } ]
                            else
                              [ "EXACT", { "value" => value } ]
                            end
                            renderer.add_element(tag, tag_attributes) do |exact|
                              content.call(exact, type, attributes)
                            end
                          end
                        else
                          content.call(renderer, type, options[type])
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      
      post_uri = URI::HTTP.build :host => params["host"], :path => params["path"], :query => "ServiceName=#{params["name"]}"
      http_post(post_uri, xml, "retries" => 5) do |post_response|
        sleep params["interval"] if params["interval"]
        xml = REXML::Document.new(post_response.body)
        error = xml.elements["/ARCXML/RESPONSE/ERROR"]
        raise InternetError.new(error.text) if error
        get_uri = URI.parse xml.elements["/ARCXML/RESPONSE/IMAGE/OUTPUT"].attributes["url"]
        get_uri.host = params["host"] if params["keep_host"]
        http_get(get_uri, "retries" => 5) do |get_response|
          File.open(tile_path, "wb") { |file| file << get_response.body }
        end
      end
      
      %x[mogrify -crop #{cropped_extents.join "x"}+#{margin}+#{margin} -format png -define png:color-type=2 "#{tile_path}"]
      [ cropped_bounds, scaling.metres_per_pixel, tile_path ]
    end
  end
end

class TiledMapService < Service
  def dataset(input_bounds, input_projection, scaling, label, options, dir)
    tile_sizes = params["tile_sizes"]
    tile_limit = params["tile_limit"]
    crops = params["crops"] || [ [ 0, 0 ], [ 0, 0 ] ]
    
    cropped_tile_sizes = [ tile_sizes, crops ].transpose.map { |tile_size, crop| tile_size - crop.inject(:+) }
    bounds = transform_bounds(input_projection, projection, input_bounds)
    extents = bounds.map { |bound| bound.max - bound.min }
    origins = bounds.transpose.first
    
    zoom, metres_per_pixel, counts = (Math::log2(Math::PI * EARTH_RADIUS / scaling.metres_per_pixel) - 7).ceil.downto(1).map do |zoom|
      metres_per_pixel = Math::PI * EARTH_RADIUS / 2 ** (zoom + 7)
      counts = [ extents, cropped_tile_sizes ].transpose.map { |extent, tile_size| (extent / metres_per_pixel / tile_size).ceil }
      [ zoom, metres_per_pixel, counts ]
    end.find do |zoom, metres_per_pixel, counts|
      counts.inject(:*) < tile_limit
    end
    
    format = options["format"]
    name = options["name"]
    
    puts "Layer: #{label}"
    puts "  downloading #{counts.inject(:*)} tiles..."
    counts.map { |count| (0...count).to_a }.inject(:product).with_progress.map do |indices|
      sleep params["interval"]
      tile_path = File.join(dir, "tile.#{indices.join('.')}.png")
      
      cropped_centre = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
        origin + tile_size * (index + 0.5) * metres_per_pixel
      end
      centre = [ cropped_centre, crops ].transpose.map { |coord, crop| coord - 0.5 * crop.inject(:-) * metres_per_pixel }
      bounds = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
        [ origin + index * tile_size * metres_per_pixel, origin + (index + 1) * tile_size * metres_per_pixel ]
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
        http_get(uri, "retries" => 5) do |response|
          File.open(tile_path, "wb") { |file| file << response.body }
          %x[mogrify -quiet -crop #{cropped_tile_sizes.join "x"}+#{crops.first.first}+#{crops.last.last} -type TrueColor -depth 8 -format png -define png:color-type=2 "#{tile_path}"]
        end
        non_blank_fraction = %x[convert "#{tile_path}" -fill white +opaque black -format "%[fx:mean]" info:].to_f
        break if non_blank_fraction > 0.995
      end
      
      [ bounds, metres_per_pixel, tile_path ]
    end
  end
end

class LPIOrthoService < Service
  def dataset(input_bounds, input_projection, scaling, label, options, dir)
    puts "Layer: #{label}"
    puts "  retrieving LPI imagery metadata..."
    images_regions = case
    when options["image"]
      { options["image"] => options["region"] }
    when options["config"]
      http_get(URI::HTTP.build(:host => params["host"], :path => options["config"]), "retries" => 5) do |response|
        vars, images = response.body.scan(/(.+)_ECWP_URL\s*?=\s*?.*"(.+)";/x).transpose
        regions = vars.map do |var|
          response.body.match(/#{var}_CLIP_REGION\s*?=\s*?\[(.+)\]/x) do |match|
            match[1].scan(/\[(.+?),(.+?)\]/x).map { |coords| coords.map { |coord| coord.to_f } }
          end
        end
        [ images, regions ].transpose.map { |image, region| { image => region } }.inject(:merge)
      end
    end
    
    bounds = transform_bounds(input_projection, projection, input_bounds)
    uri = URI::HTTP.build(:host => params["host"], :path => "/ImageX/ImageX.dll", :query => "?dsinfo?verbose=true&layers=#{images_regions.keys.join(',')}")
    images_attributes = http_get(uri, "retries" => 5) do |response|
      xml = REXML::Document.new(response.body)
      raise BadLayer.new(xml.elements["//Error"].text) if xml.elements["//Error"]
      coordspace = xml.elements["/DSINFO/COORDSPACE"]
      meterfactor = coordspace.attributes["meterfactor"].to_f
      
      xml.elements.collect("/DSINFO/LAYERS/LAYER") do |layer|
        image = layer.attributes["name"]
        sizes = [ "width", "height" ].map { |key| layer.attributes[key].to_i }
        bbox = layer.elements["BBOX"]
        layer_bounds = [ [ "tlX", "brX" ], [ "brY", "tlY" ] ].map { |keys| keys.map { |key| bbox.attributes[key].to_f } }
        resolutions = [ "cellsizeX", "cellsizeY" ].map { |key| bbox.attributes[key].to_f * meterfactor }
        
        { image => { "sizes" => sizes, "bounds" => layer_bounds, "resolutions" => resolutions, "region" => images_regions[image] } }
      end.inject(:merge)
    end.select do |image, attributes|
      bounds_intersect? bounds, attributes["bounds"]
    end
    return [] if images_attributes.empty?
    
    tile_size = params["tile_size"]
    format = images_attributes.one? ? { "type" => "jpg", "quality" => 90 } : { "type" => "png", "transparent" => true }
    puts "  downloading..."
    images_attributes.map do |image, attributes|
      zoom = [ Math::log2(scaling.metres_per_pixel / attributes["resolutions"].first).floor, 0 ].max
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
      end.inject(:product).map { |pair| pair.transpose }.map do |(tx, ty), tile_bounds|
        query = format.merge("l" => zoom, "tx" => tx, "ty" => ty, "ts" => tile_size, "layers" => image, "fillcolor" => "0x000000")
        query["inregion"] = "#{attributes["region"].flatten.join(",")},INSRC" if attributes["region"]
        [ "?image?#{query.to_query}", tile_bounds, resolutions ]
      end
    end.inject(:+).with_progress.with_index.map do |(query, tile_bounds, resolutions), index|
      uri = URI::HTTP.build :host => params["host"], :path => "/ImageX/ImageX.dll", :query => URI.escape(query)
      tile_path = File.join(dir, "tile.#{index}.#{format["type"]}")
      http_get(uri, "retries" => 5) do |response|
        begin
          xml = REXML::Document.new(response.body)
          raise BadLayer.new(xml.elements["//Error"] ? xml.elements["//Error"].text.gsub("\n", " ") : "unexpected response")
        rescue REXML::ParseException
        end
        File.open(tile_path, "wb") { |file| file << response.body }
      end
      sleep params["interval"]
      [ tile_bounds, resolutions.first, tile_path ]
    end
  end
end

class OneEarthDEMRelief < Service
  def initialize(params)
    super(params)
    @projection = WGS84
  end
  
  def dataset(input_bounds, input_projection, scaling, label, options, dir)
    bounds = transform_bounds(input_projection, projection, input_bounds)
    bounds = bounds.map { |bound| [ ((bound.first - 0.01) / 0.125).floor * 0.125, ((bound.last + 0.01) / 0.125).ceil * 0.125 ] }
    counts = bounds.map { |bound| ((bound.max - bound.min) / 0.125).ceil }
    units_per_pixel = 0.125 / 300
    
    puts "Layer: #{label}"
    puts "  downloading..."
    tile_paths = [ counts, bounds ].transpose.map do |count, bound|
      boundaries = (0..count).map { |index| bound.first + index * 0.125 }
      [ boundaries[0..-2], boundaries[1..-1] ].transpose
    end.inject(:product).with_progress.map.with_index do |tile_bounds, index|
      tile_path = File.join(dir, "tile.#{index}.png")
      bbox = tile_bounds.transpose.map { |corner| corner.join "," }.join ","
      query = {
        "request" => "GetMap",
        "layers" => "gdem",
        "srs" => projection,
        "width" => 300,
        "height" => 300,
        "format" => "image/png",
        "styles" => "short_int",
        "bbox" => bbox
      }.to_query
      uri = URI::HTTP.build :host => "onearth.jpl.nasa.gov", :path => "/wms.cgi", :query => URI.escape(query)

      http_get(uri, "retries" => 5) do |response|
        File.open(tile_path, "wb") { |file| file << response.body }
        write_world_file([ tile_bounds.first.min, tile_bounds.last.max ], units_per_pixel, 0, "#{tile_path}w")
        sleep params["interval"]
      end
      %Q["#{tile_path}"]
    end
    
    vrt_path = File.join(dir, "dem.vrt")
    relief_path = File.join(dir, "output.tif")
    output_path = File.join(dir, "output.png")
    %x[gdalbuildvrt "#{vrt_path}" #{tile_paths.join " "}]
    
    case options["name"]
    when "shaded-relief"
      altitude = params["altitude"]
      azimuth = options["azimuth"]
      exaggeration = params["exaggeration"]
      %x[gdaldem hillshade -s 111120 -alt #{altitude} -z #{exaggeration} -az #{azimuth} "#{vrt_path}" "#{relief_path}" -q]
    when "color-relief"
      colours = { "0%" => "black", "100%" => "white" }
      colour_path = File.join(dir, "colours.txt")
      File.open(colour_path, "w") do |file|
        colours.each { |elevation, colour| file.puts "#{elevation} #{colour}" }
      end
      %x[gdaldem color-relief "#{vrt_path}" "#{colour_path}" "#{relief_path}" -q]
    end
    %x[convert "#{relief_path}" -quiet -type TrueColor -depth 8 -define png:color-type=2 "#{output_path}"]
    
    [ [ bounds, units_per_pixel, output_path ] ]
  end
end

class UTMGridService < Service
  def self.zone(projection, coords)
    (coords.reproject(projection, WGS84).first / 6).floor + 31
  end
  
  attr_reader :zone
  
  def initialize(params)
    super(params)
    @zone = params["zone"]
    @projection = "+proj=utm +zone=#{zone} +south +datum=WGS84"
  end
  
  def zone_contains?(coords)
    UTMGridService.zone(projection, coords) == zone
  end
  
  def pixel_for(coords, bounds, scaling)
    [ coords, bounds, [ 1, -1 ] ].transpose.map.with_index do |(coord, bound, sign), index|
      ((coord - bound[index]) * sign / scaling.metres_per_pixel).round
    end
  end
    
  def dataset(input_bounds, input_projection, scaling, label, options, dir)
    puts "Layer: #{label}"
    puts "  calculating..."
    intervals, fontsize, family, weight = params.values_at("intervals", "fontsize", "family", "weight")
    bounds = transform_bounds(input_projection, projection, input_bounds)
    
    tick_indices = [ bounds, intervals ].transpose.map do |bound, interval|
      ((bound.first / interval).floor .. (bound.last / interval).ceil).to_a
    end
    tick_coords = [ tick_indices, intervals ].transpose.map { |indices, interval| indices.map { |index| index * interval } }
    centre_coords = bounds.map { |bound| 0.5 * bound.inject(:+) }
    centre_indices = [ centre_coords, tick_indices, intervals ].transpose.map do |coord, indices, interval|
      indices.index((coord / interval).round)
    end
    
    draw_string = case options["name"]
    when "grid"
      string = [ :to_a, :reverse ].map do |order|
        tick_coords.send(order).first.map do |perpendicular_coord|
          line_coords = tick_coords.send(order).last.map do |parallel_coord|
            [ perpendicular_coord, parallel_coord ].send(order)
          end.select { |coords| zone_contains? coords }
          line_coords.length > 1 ? [ line_coords.first, line_coords.last ] : nil
        end.compact
      end.inject(:+).map do |end_coords|
        end_coords.map { |coords| pixel_for coords, bounds, scaling }
      end.map do |end_pixels|
        %Q[-draw "line #{end_pixels.first.first},#{end_pixels.first.last} #{end_pixels.last.first},#{end_pixels.last.last}"]
      end.join " "
      "-stroke white -strokewidth 1 #{string}"
    when "eastings", "northings"
      margin = 0.04 * scaling.ppi
      eastings = options["name"] == "eastings"
      index = eastings ? 0 : 1
      angle = eastings ? -90 : 0
      divisor = intervals[index] % 1000 == 0 ? 1000 : 1
      string = tick_coords[index].map do |coord|
        [ coord, tick_coords[1-index][centre_indices[1-index]] ].send(index == 0 ? :to_a : :reverse)
      end.select do |coords|
        zone_contains? coords
      end.map do |coords|
        [ pixel_for(coords, bounds, scaling), coords[index] ]
      end.map do |pixel, coord|
        %Q[-draw "translate #{pixel.first},#{pixel.last} rotate #{angle} text #{margin},#{-margin} '#{coord / divisor}'"]
      end.join " "
      %Q[-fill white -style Normal -pointsize #{fontsize} -family "#{family}" -weight #{weight} #{string}]
    end
    
    dimensions = bounds.map { |bound| ((bound.max - bound.min) / scaling.metres_per_pixel).ceil }
    path = File.join(dir, "#{options["name"]}.tif")
    %x[convert -size #{dimensions.join 'x'} canvas:black -units PixelsPerInch -density #{scaling.ppi} -type TrueColor -depth 8 #{draw_string} "#{path}"]

    [ [ bounds, scaling.metres_per_pixel, path ] ]
  end
end

class AnnotationService < Service
  def dataset(input_bounds, input_projection, scaling, label, options, dir)
    puts "Layer: #{label}"
    []
  end
  
  def post_process(path, centre, projection, dimensions, scaling, rotation, options)
    draw_string = draw(centre, projection, dimensions, scaling, rotation, options)
    %x[mogrify -quiet -units PixelsPerInch -density #{scaling.ppi} #{draw_string} "#{path}"]
  end
end

class DeclinationService < AnnotationService
  def self.get_declination(coords, projection)
    degrees_minutes_seconds = coords.reproject(projection, WGS84).map do |coord|
      [ (coord > 0 ? 1 : -1) * coord.abs.floor, (coord.abs * 60).floor % 60, (coord.abs * 3600).round % 60 ]
    end
    today = Date.today
    year_month_day = [ today.year, today.month, today.day ]
    url = "http://www.ga.gov.au/bin/geoAGRF?latd=%i&latm=%i&lats=%i&lond=%i&lonm=%i&lons=%i&elev=0&year=%i&month=%i&day=%i&Ein=D" % (degrees_minutes_seconds.reverse.flatten + year_month_day)
    http_get(URI.parse url) do |response|
      /D\s*=\s*(\d+\.\d+)/.match(response.body) { |match| match.captures[0].to_f }
    end
  end
  
  def draw(centre, projection, dimensions, scaling, rotation, options)
    spacing = params["spacing"]
    declination = params["angle"] || DeclinationService.get_declination(centre, projection)
    angle = declination + rotation
    x_spacing = spacing / Math::cos(angle * Math::PI / 180.0) / scaling.metres_per_pixel
    dx = dimensions.last * Math::tan(angle * Math::PI / 180.0)
    x_min = [ 0, dx ].min
    x_max = [ dimensions.first, dimensions.first + dx ].max
    line_count = ((x_max - x_min) / x_spacing).ceil
    
    string = (1..line_count).map do |n|
      x_min + n * x_spacing
    end.map do |x|
       %Q[-draw "line #{x.round},0 #{(x - dx).round},#{dimensions.last}"]
    end.join " "
    
    %Q[-fill black -draw "color 0,0 reset" -stroke white -strokewidth 1 #{string}]
  end
end

class ControlService < AnnotationService
  def dataset(*args)
    params["file"] ? super(*args) : nil
  end
  
  def draw(centre, projection, dimensions, scaling, rotation, options)
    waypoints, names = read_waypoints(params["file"]).select do |waypoint, name|
      case options["name"]
      when /control/ then name[/\d{2,3}|HH/]
      when /waterdrop/ then name[/W/]
      end
    end.transpose
    return "" unless waypoints
    
    radius = params["diameter"] * scaling.ppi / 25.4 / 2
    strokewidth = params["thickness"] * scaling.ppi / 25.4
    family = params["family"]
    fontsize = options["name"] == "waterdrops" ? params["waterdrop-size"] * 3.7 : params["fontsize"]
    weight = params["weight"]
    cx, cy = dimensions.map { |dimension| 0.5 * dimension }
    
    string = [ waypoints.reproject(WGS84, projection), names ].transpose.map do |coords, name|
      offsets = [ coords, centre, [ 1, -1 ] ].transpose.map { |coord, cent, sign| (coord - cent) * sign / scaling.metres_per_pixel }
      x, y = offsets.rotate(rotation * Math::PI / 180.0)
      case options["name"]
      when "control-circles"
        case name
        when /HH/ then %Q[-draw "polygon #{cx + x},#{cy + y - radius} #{cx + x + radius * Math::sqrt(0.75)},#{cy + y + radius * 0.5}, #{cx + x - radius * Math::sqrt(0.75)},#{cy + y + radius * 0.5}"]
        else %Q[-draw "circle #{cx + x},#{cy + y} #{cx + x + radius},#{cy + y}"]
        end
      when "control-labels"
        %Q[-draw "text #{cx + x + radius},#{cy + y - radius} '#{name[/\d{2,3}|HH/]}'"]
      when "waterdrops"
        %Q[-draw "gravity Center text #{x},#{y} 'S'"]
      end
    end.join " "
    
    case options["name"]
    when "control-circles"
      %Q[-fill black -draw "color 0,0 reset" -stroke white -strokewidth #{strokewidth} #{string}]
    when "control-labels"
      %Q[-fill black -draw "color 0,0 reset" -fill white -pointsize #{fontsize} -weight #{weight} -family "#{family}" #{string}]
    when "waterdrops"
      %Q[-fill black -draw "color 0,0 reset" -stroke white -strokewidth #{strokewidth} -pointsize #{fontsize} -family Wingdings #{string}]
    end
  rescue BadGpxKmlFile => e
    raise BadLayer.new("Error: #{e.message} not a valid GPX or KML file")
  end
end

output_dir = Dir.pwd
config = YAML.load(
%q[
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
  intervals:
    - 1000
    - 1000
  fontsize: 6.0
  family: Arial Narrow
  weight: 200
relief:
  altitude: 45
  azimuth:
    - 315
    - 45
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
  - layered.tif
exclude:
  - utm
  - aerial-lpi-sydney
  - aerial-lpi-towns
colours:
  pine: '#009f00'
  orchards-plantations: '#009f00'
  built-up-areas: '#F8FF73'
  contours: '#9c3026'
  ancillary-contours: '#9c3026'
  swamp-wet: '#00bdff'
  swamp-dry: '#e3bf9a'
  watercourses: '#0033ff'
  ocean: '#7b96ff'
  dams: '#0033ff'
  water-tanks: '#7b96ff'
  water-areas: '#7b96ff'
  water-areas-intermittent: '#7b96ff'
  water-area-boundaries: '#0033ff'
  water-areas-intermittent-boundaries: '#0033ff'
  reef: 'Cyan'
  sand: '#ff6600'
  intertidal: '#1b2e7b'
  inundation: '#00bdff'
  cliffs: '#c6c6c7'
  clifftops: '#ff00ba'
  rocks-pinnacles: '#ff00ba'
  buildings: '#111112'
  building-areas: '#666667'
  cadastre: '#888889'
  act-cadastre: '#888889'
  act-border: '#888889'
  misc-perimeters: '#333334'
  excavation: '#333334'
  coastline: '#000001'
  dam-walls: '#000001'
  cableways: '#000001'
  wharves: '#000001'
  bridges-culverts: '#000001'
  floodways: '#0033ff'
  pathways: '#000001'
  tracks-4wd: 'Dark Orange'
  tracks-vehicular: 'Dark Orange'
  roads-unsealed: 'Dark Orange'
  roads-sealed: 'Red'
  gates-grids: '#000001'
  railways: '#000001'
  pipelines: '#00a6e5'
  landing-grounds: '#333334'
  transmission-lines: '#000001'
  caves: '#000001'
  towers: '#000001'
  windmills: '#000001'
  beacons: '#000001'
  mines: '#000001'
  yards: '#000001'
  trig-points: '#000001'
  labels: '#000001'
  waterdrops: '#0033ff'
  control-circles: '#9e00c0'
  control-labels: '#9e00c0'
  declination: '#000001'
  utm-54-grid: '#000001'
  utm-54-eastings: '#000001'
  utm-54-northings: '#000001'
  utm-55-grid: '#000001'
  utm-55-eastings: '#000001'
  utm-55-northings: '#000001'
  utm-56-grid: '#000001'
  utm-56-eastings: '#000001'
  utm-56-northings: '#000001'
patterns:
  pine:
    00000000100000000000001111111111100000
    00000000100000000000000000010000000000
    00000001110000000000000000010000000000
    00000001110000000000000000000000000000
    00000011111000000000000000000000000000
    00000011111000000000000000000000000000
    00000111111100000000000000000000000000
    00000111111100000000000000000000000000
    00000000100000000000000000000000000000
    00000001110000000000000000000000000000
    00000011111000000000000000000000000000
    00000111111100000000000000000000000000
    00001111111110000000000000000000000000
    00011111111111000000000000010000000000
    00000000100000000000000000010000000000
    00000000100000000000000000111000000000
    00000000000000000000000000111000000000
    00000000000000000000000001111100000000
    00000000000000000000000001111100000000
    00000000000000000000000011111110000000
    00000000000000000000000011111110000000
    00000000000000000000000000010000000000
    00000000000000000000000000111000000000
    00000000000000000000000001111100000000
    00000000000000000000000011111110000000
    00000000000000000000000111111111000000
  water-areas-intermittent:
    01,10,01,00,00,00
    10,50,10,00,00,00
    01,10,01,00,00,00
    00,00,00,01,10,01
    00,00,00,10,50,10
    00,00,00,01,10,01
  sand:
    01,10,01,00,00,00
    10,50,10,00,00,00
    01,10,01,00,00,00
    00,00,00,01,10,01
    00,00,00,10,50,10
    00,00,00,01,10,01
  intertidal:
    01,10,01,00,00,00
    10,50,10,00,00,00
    01,10,01,00,00,00
    00,00,00,01,10,01
    00,00,00,10,50,10
    00,00,00,01,10,01
  reef:
    00000
    00100
    01110
    00100
    00000
  orchards-plantations:
    111110000
    111110000
    111110000
    111110000
    111110000
    000000000
    000000000
    000000000
    000000000
glow:
  labels: true
  utm-54-eastings: true
  utm-54-northings: true
  utm-55-eastings: true
  utm-55-northings: true
  utm-56-eastings: true
  utm-56-northings: true
]
)
config["controls"]["file"] = "controls.gpx" if File.exists? "controls.gpx"
config = config.deep_merge YAML.load(File.open(File.join(output_dir, "config.yml")))
{
  "utm" => %w{utm-54-grid utm-54-eastings utm-54-northings utm-55-grid utm-55-eastings utm-55-northings utm-56-grid utm-56-eastings utm-56-northings},
  "aerial" => %w{aerial-google aerial-nokia aerial-lpi-sydney aerial-lpi-eastcoast aerial-lpi-towns aerial-lpi-ads40},
  "coastal" => %w{ocean reef intertidal coastline wharves},
  "act" => %w{act-rivers-and-creeks act-urban-land act-lakes-and-major-rivers act-plantations act-roads-sealed act-roads-unsealed act-vehicular-tracks act-adhoc-fire-access}
}.each do |shortcut, layers|
  config["exclude"] += layers if config["exclude"].delete(shortcut)
end

map_name = config["name"]
scaling = Scaling.new(config["scale"], config["ppi"])

wgs84_points = case
when config["zone"] && config["eastings"] && config["northings"]
  config.values_at("eastings", "northings").inject(:product).reproject("+proj=utm +zone=#{config["zone"]} +south +datum=WGS84", WGS84)
when config["longitudes"] && config["latitudes"]
  config.values_at("longitudes", "latitudes").inject(:product)
when config["size"] && config["zone"] && config["easting"] && config["northing"]
  [ config.values_at("easting", "northing").reproject("+proj=utm +zone=#{config["zone"]} +south +datum=WGS84", WGS84) ]
when config["size"] && config["longitude"] && config["latitude"]
  [ config.values_at("longitude", "latitude") ]
when config["bounds"] || File.exists?("bounds.kml")
  config["bounds"] ||= "bounds.kml"
  trackpoints = read_track(config["bounds"])
  waypoints = read_waypoints(config["bounds"])
  config["margin"] = 0 unless waypoints.any?
  trackpoints.any? ? trackpoints : waypoints.transpose.first
else
  abort "Error: map extent must be provided as zone/eastings/northings, zone/easting/northing/size, latitudes/longitudes or latitude/longitude/size"
end

projection_centre = wgs84_points.transpose.map { |coords| 0.5 * (coords.max + coords.min) }
projection = "+proj=tmerc +lat_0=0.000000000 +lon_0=#{projection_centre.first} +k=0.999600 +x_0=500000.000 +y_0=10000000.000 +ellps=WGS84 +datum=WGS84 +units=m"
wkt = %Q{PROJCS["",GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.017453292519943295]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",500000.0],PARAMETER["False_Northing",10000000.0],PARAMETER["Central_Meridian",#{projection_centre.first}],PARAMETER["Scale_Factor",0.9996],PARAMETER["Latitude_Of_Origin",0.0],UNIT["Meter",1.0]]}
proj_path = File.join(output_dir, "#{map_name}.prj")
File.open(proj_path, "w") { |file| file.puts projection }

config["rotation"] = -(config["declination"]["angle"] || DeclinationService.get_declination(projection_centre, WGS84)) if config["rotation"] == "magnetic"

if config["size"]
  sizes = config["size"].split(/[x,]/).map { |number| number.to_f }
  abort("Error: invalid map size: #{config["size"]}") unless sizes.length == 2 && sizes.all? { |size| size > 0.0 }
  extents = sizes.map { |size| size * 0.001 * scaling.scale }
  rotation = config["rotation"]
  abort("Error: cannot specify map size and auto-rotation together") if rotation == "auto"
  abort "Error: map rotation must be between +/-45 degrees" unless rotation.abs <= 45
  centre = projection_centre.reproject(WGS84, projection)
else
  puts "Calculating map bounds..."
  bounding_points = wgs84_points.reproject(WGS84, projection)
  if config["rotation"] == "auto"
    centre, extents, rotation = minimum_bounding_box(bounding_points)
    rotation *= 180.0 / Math::PI
  else
    rotation = config["rotation"]
    abort "Error: map rotation must be between -45 and +45 degrees" unless rotation.abs <= 45
    centre, extents = bounding_points.map do |point|
      point.rotate(-rotation * Math::PI / 180.0)
    end.transpose.map do |coords|
      [ coords.max, coords.min ]
    end.map do |max, min|
      [ 0.5 * (max + min), max - min ]
    end.transpose
    centre.rotate!(rotation * Math::PI / 180.0)
  end
  extents.map! { |extent| extent + 2 * config["margin"] * 0.001 * scaling.scale } if config["bounds"]
end
dimensions = extents.map { |extent| (extent / scaling.metres_per_pixel).ceil }

topleft = [ centre, extents.rotate(-rotation * Math::PI / 180.0), [ :-, :+ ] ].transpose.map { |coord, extent, plus_minus| coord.send(plus_minus, 0.5 * extent) }
world_file_path = File.join(output_dir, "#{map_name}.wld")
write_world_file(topleft, scaling.metres_per_pixel, rotation, world_file_path)

enlarged_extents = [ extents.first * Math::cos(rotation * Math::PI / 180.0) + extents.last * Math::sin(rotation * Math::PI / 180.0).abs, extents.first * Math::sin(rotation * Math::PI / 180.0).abs + extents.last * Math::cos(rotation * Math::PI / 180.0) ]
bounds = [ centre, enlarged_extents ].transpose.map { |coord, extent| [ coord - 0.5 * extent, coord + 0.5 * extent ] }

topo_portlet = ArcIMS.new(
  "host" => "gsp.maps.nsw.gov.au",
  "path" => "/servlet/com.esri.esrimap.Esrimap",
  "name" => "topo_portlet",
  "keep_host" => true,
  "projection" => projection,
  "wkt" => wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "dpi" => 96,
  "envelope" => {
    "bounds" => [ [ 140.011127032369, 154.62466299763 ], [ -37.740334035, -27.924909045 ] ],
    "projection" => "EPSG:4283"
  })
cad_portlet = ArcIMS.new(
  "host" => "gsp.maps.nsw.gov.au",
  "path" => "/servlet/com.esri.esrimap.Esrimap",
  "name" => "cad_portlet",
  "keep_host" => true,
  "projection" => projection,
  "wkt" => wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "dpi" => 74,
  "envelope" => {
    "bounds" => [ [ 140.05983881892, 154.575951211079 ], [ -37.740334035, -27.924909045 ] ],
    "projection" => "EPSG:4283"
  })
act_heritage = ArcIMS.new(
  "host" => "www.gim.act.gov.au",
  "path" => "/arcims/ims",
  "name" => "Heritage",
  "projection" => projection,
  "wkt" => wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "dpi" => 96,
  "envelope" => {
    "bounds" => [ [ 660000, 718000 ], [ 6020000, 6107000 ] ],
    "projection" => "EPSG:32755"
  })
act_dog = ArcIMS.new(
  "host" => "www.gim.act.gov.au",
  "path" => "/arcims/ims",
  "name" => "dog",
  "projection" => projection,
  "wkt" => wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "dpi" => 96,
  "envelope" => {
    "bounds" => [ [ 659890.105040274, 720782.12808229 ], [ 6022931.0546655, 6111100.93973127 ] ],
    "projection" => "EPSG:32755"
  })
declination_service = DeclinationService.new(config["declination"])
control_service = ControlService.new(config["controls"])
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
oneearth_relief = OneEarthDEMRelief.new({ "interval" => 0.3, "resample" => "bilinear" }.merge config["relief"])

services = {
  topo_portlet => {
    "vegetation" => {
      "image" => "Vegetation_1"
    },
    "labels" => [
      { # contour labels
        "from" => "Contour_1",
        "where" => "MOD(elevation, #{config["contours"]["labels"]}) = 0 AND elevation > 0",
        "label" => { "field" => "delivsdm:geodb.Contour.Elevation", "linelabelposition" => "placeontop" },
        "lookup" => "delivsdm:geodb.Contour.sourceprogram",
        "text" => { config["contours"]["source"] => { "fontsize" => 4.2, "fontstyle" => "italic" } }
      },
      { # watercourse labels
        "from" => "HydroLine_Label_1",
        "where" => "ClassSubtype = 1",
        "label" => { "field" => "delivsdm:geodb.HydroLine.HydroName delivsdm:geodb.HydroLine.HydroNameType", "linelabelposition" => "placeabovebelow" },
        "lookup" => "delivsdm:geodb.HydroLine.relevance",
        "text" => {
          1 => { "fontsize" => 10.9, "printmode" => "allupper", "fontstyle" => "italic", "interval" => 2.0 },
          2 => { "fontsize" => 10.1, "printmode" => "allupper", "fontstyle" => "italic", "interval" => 2.0 },
          3 => { "fontsize" => 9.3, "printmode" => "allupper", "fontstyle" => "italic", "interval" => 2.0 },
          4 => { "fontsize" => 8.5, "printmode" => "allupper", "fontstyle" => "italic", "interval" => 2.0 },
          5 => { "fontsize" => 7.7, "printmode" => "titlecaps", "fontstyle" => "italic", "interval" => 2.0 },
          6 => { "fontsize" => 6.9, "printmode" => "titlecaps", "fontstyle" => "italic", "interval" => 2.0 },
          7 => { "fontsize" => 6.1, "printmode" => "titlecaps", "fontstyle" => "italic", "interval" => 1.5 },
          8 => { "fontsize" => 5.3, "printmode" => "titlecaps", "fontstyle" => "italic", "interval" => 1.5 },
          9 => { "fontsize" => 4.5, "printmode" => "titlecaps", "fontstyle" => "italic", "interval" => 1.5 },
          10 => { "fontsize" => 3.7, "printmode" => "titlecaps", "fontstyle" => "italic", "interval" => 1.5 }
        }
      },
      { # waterbody labels
        "from" => "HydroArea_Label_1",
        "label" => { "field" => "delivsdm:geodb.HydroArea.HydroName delivsdm:geodb.HydroArea.HydroNameType", "rotationalangles" => rotation },
        "lookup" => "delivsdm:geodb.HydroArea.classsubtype",
        "text" => { 1 => { "fontsize" => 5.5, "printmode" => "titlecaps" } }
      },
      { # fuzzy water labels
        "from" => "FuzzyExtentWaterArea_1",
        "label" => { "field" => "delivsdm:geodb.FuzzyExtentWaterArea.HydroName delivsdm:geodb.FuzzyExtentWaterArea.HydroNameType", "rotationalangles" => rotation },
        "lookup" => "delivsdm:geodb.FuzzyExtentWaterArea.classsubtype",
        "text" => { 2 => { "fontsize" => 4.2, "fontstyle" => "italic", "printmode" => "titlecaps" } }
      },
      { # road/track/pathway labels
        "from" => "RoadSegment_Label_1",
        "lookup" => "delivsdm:geodb.RoadSegment.FunctionHierarchy",
        "label" => { "field" => "delivsdm:geodb.RoadSegment.RoadNameBase delivsdm:geodb.RoadSegment.RoadNameType delivsdm:geodb.RoadSegment.RoadNameSuffix" },
        "text" => {
          "1;2" => { "fontsize" => 6.4, "fontstyle" => "italic", "printmode" => "allupper", "interval" => 1.0 },
          "3;4;5" => { "fontsize" => 5.4, "fontstyle" => "italic", "printmode" => "allupper", "interval" => 1.0 },
          "6;8;9" => { "fontsize" => 4.0, "fontstyle" => "italic", "printmode" => "allupper", "interval" => 0.6 },
          7 => { "fontsize" => 3.4, "fontstyle" => "italic", "printmode" => "allupper", "interval" => 0.6 },
        }
      },
      { # fuzzy area labels
        "from" => "FuzzyExtentArea_Label_1",
        "label" => { "field" => "delivsdm:geodb.FuzzyExtentArea.GeneralName", "rotationalangles" => rotation },
        "text" => { "fontsize" => 5.5, "printmode" => "allupper" }
      },
      { # fuzzy line labels (valleys, beaches)
        "from" => "FuzzyExtentLine_Label_1",
        "label" => { "field" => "delivsdm:geodb.FuzzyExtentLine.GeneralName", "linelabelposition" => "placeabovebelow" },
        "lookup" => "delivsdm:geodb.FuzzyExtentLine.fuzzylinefeaturetype",
        "text" => {
          18 => { "fontsize" => 5.5, "printmode" => "allupper", "interval" => 2.0 },
          2 => { "fontsize" => 5.5, "printmode" => "allupper", "interval" => 0.2 },
        }
      },
      { # fuzzy line labels (dunes, general, ranges)
        "from" => "FuzzyExtentLine_Label_1",
        "label" => { "field" => "delivsdm:geodb.FuzzyExtentLine.GeneralName", "linelabelposition" => "placeontop" },
        "lookup" => "delivsdm:geodb.FuzzyExtentLine.fuzzylinefeaturetype",
        "text" => {
          "3;5;13" => { "fontsize" => 6.5, "printmode" => "allupper" }
        }
      },
      { # building labels
        "from" => "BuildingComplexPoint_Label_1",
        "label" => { "field" => "delivsdm:geodb.BuildingComplexPoint.GeneralName", "rotationalangles" => rotation },
        "text" => { "fontsize" => 3.8, "fontstyle" => "italic", "printmode" => "titlecaps", "interval" => 2.0 }
      },
      { # cave labels
        "from" => "DLSPoint_Label_1",
        "lookup" => "delivsdm:geodb.DLSPoint.ClassSubtype",
        "label" => { "field" => "delivsdm:geodb.DLSPoint.GeneralName", "rotationalangles" => rotation },
        "text" => { 1 => { "fontsize" => 4.8, "printmode" => "titlecaps", "interval" => 2.0 } }
      },
      { # cableway labels
        "from" => "Cableway_Label_1",
        "label" => { "field" => "delivsdm:geodb.Cableway.GeneralName", "linelabelposition" => "placeabovebelow" },
        "lookup" => "delivsdm:geodb.Cableway.ClassSubtype",
        "text" => { "1;2" => { "fontsize" => 3, "fontstyle" => "italic", "printmode" => "allupper", "font" => "Arial Narrow", "interval" => 0.5 } }
      },
    ],
    "contours" => [
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, #{config["contours"]["interval"]}) = 0 AND sourceprogram = #{config["contours"]["source"]}",
        "lookup" => "delivsdm:geodb.Contour.ClassSubtype",
        "line" => { 1 => { "width" => 1 } },
        "hashline" => { 2 => { "width" => 2, "linethickness" => 1, "thickness" => 1, "interval" => 8 } }
      },
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, #{config["contours"]["index"]}) = 0 AND elevation > 0 AND sourceprogram = #{config["contours"]["source"]}",
        "lookup" => "delivsdm:geodb.Contour.ClassSubtype",
        "line" => { 1 => { "width" => 2 } },
        "hashline" => { 2 => { "width" => 3, "linethickness" => 2, "thickness" => 1, "interval" => 8 } }
      },
    ],
    "ancillary-contours" => {
      "from" => "Contour_1",
      "where" => "sourceprogram = #{config["contours"]["source"]}",
      "lookup" => "delivsdm:geodb.Contour.ClassSubtype",
      "line" => { 3 => { "width" => 1, "type" => "dash" } },
    },
    "watercourses" => {
      "from" => "HydroLine_1",
      "where" => "ClassSubtype = 1",
      "lookup" => "delivsdm:geodb.HydroLine.Perenniality",
      "line" => {
        1 => { "width" => 2 },
        2 => { "width" => 1 },
        3 => { "width" => 1, "type" => "dash" }
      }
    },
    "water-areas" => [
      {
        "from" => "HydroArea_1",
        "lookup" => "delivsdm:geodb.HydroArea.perenniality",
        "polygon" => { 1 => { "boundary" => false } }
      },
      {
        "from" => "TankArea_1",
        "lookup" => "delivsdm:geodb.TankArea.tanktype",
        "polygon" => { 1 => { "boundary" => false } }
      }
    ],
    "water-area-boundaries" => [
      {
        "from" => "HydroArea_1",
        "lookup" => "delivsdm:geodb.HydroArea.perenniality",
        "line" => { 1 => { "width" => 2 } }
      },
      {
        "from" => "TankArea_1",
        "lookup" => "delivsdm:geodb.TankArea.tanktype",
        "line" => { 1 => { "width" => 2 } }
      }
    ],
    "water-areas-intermittent" => {
      "from" => "HydroArea_1",
      "lookup" => "delivsdm:geodb.HydroArea.perenniality",
      "polygon" => { "2;3" => { "boundary" => false } }
    },
    "water-areas-intermittent-boundaries" => {
      "from" => "HydroArea_1",
      "lookup" => "delivsdm:geodb.HydroArea.perenniality",
      "line" => { "2;3" => { "width" => 1 } }
    },
    "dams" => {
      "from" => "HydroPoint_1",
      "lookup" => "delivsdm:geodb.HydroPoint.ClassSubtype",
      "marker" => { 1 => { "type" => "square", "width" => 0.8 } }
    },
    "water-tanks" => {
      "from" => "TankPoint_1",
      "lookup" => "delivsdm:geodb.TankPoint.tanktype",
      "marker" => { 1 => { "type" => "circle", "width" => 0.8 } }
    },
    "ocean" => {
      "from" => "FuzzyExtentWaterArea_1",
      "lookup" => "delivsdm:geodb.FuzzyExtentWaterArea.classsubtype",
      "polygon" => { 3 => { } }
    },
    "coastline" => {
      "from" => "Coastline_1",
      "line" => { "width" => 1 }
    },
    "roads-sealed" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "where" => "(Surface = 0 OR Surface = 1) AND ClassSubtype != 8",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => {
        "1;2;3" => { "width" => 7, "captype" => "round" },
        "4;5"   => { "width" => 5, "captype" => "round" },
        "6"     => { "width" => 3, "captype" => "round" },
        "7"     => { "width" => 2, "captype" => "round" }
      }
    },
    "roads-unsealed" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "where" => "Surface = 2",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => {
        "1;2;3" => { "width" => 7, "captype" => "round" },
        "4;5"   => { "width" => 5, "captype" => "round" },
        "6"     => { "width" => 3, "captype" => "round" },
        "7"     => { "width" => 2, "captype" => "round" }
      }
    },
    "tracks-vehicular" => {
      "scale" => 0.6,
      "from" => "RoadSegment_1",
      "where" => "Surface = 2",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => { 8 => { "width" => 2, "type" => "dash", "captype" => "round" } },
    },
    "tracks-4wd" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "where" => "Surface = 3 OR Surface = 4",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => { 8 => { "width" => 2, "type" => "dash", "captype" => "round" } },
    },
    "pathways" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => { 9 => { "width" => 2, "type" => "dash", "captype" => "round" } },
    },
    "bridges-culverts" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "where" => "RoadOnType = 2 OR RoadOnType = 5",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => {
        "1;2;3" => { "width" => 10, "captype" => "square" },
        "4;5"   => { "width" => 8, "captype" => "square" },
        "6;8"   => { "width" => 6, "captype" => "square" },
        "7"     => { "width" => 5, "captype" => "square" },
      }
    },
    "floodways" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "where" => "RoadOnType = 4",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => {
        "1;2;3" => { "width" => 10, "captype" => "square" },
        "4;5"   => { "width" => 8, "captype" => "square" },
        "6;8"   => { "width" => 6, "captype" => "square" },
        "7"     => { "width" => 5, "captype" => "square" },
      }
    },
    "buildings" => {
      "from" => "GeneralCulturalPoint_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.classsubtype",
      "marker" => { 5 => { "type" => "square", "width" => 0.5 } }
    },
    "intertidal" => {
      "from" => "DLSArea_1",
      "lookup" => "delivsdm:geodb.DLSArea.ClassSubtype",
      "polygon" => { 1 => { } }
    },
    "inundation" => {
      "from" => "DLSArea_1",
      "lookup" => "delivsdm:geodb.DLSArea.ClassSubtype",
      "polygon" => { 2 => { } }
    },
    "reef" => {
      "from" => "DLSArea_1",
      "lookup" => "delivsdm:geodb.DLSArea.ClassSubtype",
      "polygon" => { 4 => { } }
    },
    "rock-area" => {
      "from" => "DLSArea_1",
      "lookup" => "delivsdm:geodb.DLSArea.ClassSubtype",
      "polygon" => { "5;6" => { } }
    },
    "sand" => {
      "from" => "DLSArea_1",
      "lookup" => "delivsdm:geodb.DLSArea.ClassSubtype",
      "polygon" => { 7 => { } }
    },
    "swamp-wet" => {
      "from" => "DLSArea_1",
      "lookup" => "delivsdm:geodb.DLSArea.ClassSubtype",
      "polygon" => { 8 => { } }
    },
    "swamp-dry" => {
      "from" => "DLSArea_1",
      "lookup" => "delivsdm:geodb.DLSArea.ClassSubtype",
      "polygon" => { 9 => { } }
    },
    "cliffs" => {
      "from" => "DLSArea_1",
      "lookup" => "delivsdm:geodb.DLSArea.ClassSubtype",
      "polygon" => { 11 => { } }
    },
    "clifftops" => {
      "from" => "DLSLine_1",
      "lookup" => "delivsdm:geodb.DLSLine.ClassSubtype",
      "scale" => 0.25,
      "line" => { 1 => { "width" => 2, "type" => "dot", "antialiasing" => false } }
    },
    "excavation" => {
      "from" => "DLSLine_1",
      "lookup" => "delivsdm:geodb.DLSLine.ClassSubtype",
      "scale" => 0.25,
      "line" => { 3 => { "width" => 2, "type" => "dot", "antialiasing" => false } }
    },
    "caves" => {
      "from" => "DLSPoint_1",
      "lookup" => "delivsdm:geodb.DLSPoint.ClassSubtype",
      "truetypemarker" => { 1 => { "font" => "ESRI Default Marker", "fontsize" => 7, "character" => 216, "angle" => rotation } }
    },
    "rocks-pinnacles" => {
      "from" => "DLSPoint_1",
      "lookup" => "delivsdm:geodb.DLSPoint.ClassSubtype",
      "truetypemarker" => { "2;5;6" => { "font" => "ESRI Default Marker", "character" => 107, "fontsize" => 3 } }
    },
    "built-up-areas" => {
      "from" => "GeneralCulturalArea_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalArea.ClassSubtype",
      "polygon" => { 7 => { } }
    },
    "pine" => {
      "from" => "GeneralCulturalArea_1",
      "where" => "ClassSubtype = 6",
      "lookup" => "delivsdm:geodb.GeneralCulturalArea.GeneralCulturalType",
      "polygon" => { 1 => { } }
    },
    "orchards-plantations" => {
      "from" => "GeneralCulturalArea_1",
      "where" => "ClassSubtype = 6",
      "lookup" => "delivsdm:geodb.GeneralCulturalArea.GeneralCulturalType",
      "polygon" => { "0;2;3;4" => { } }
    },
    "building-areas" => {
      "from" => "GeneralCulturalArea_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalArea.ClassSubtype",
      "polygon" => { 5 => { } }
    },
    "dam-walls" => {
      "from" => "GeneralCulturalLine_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalLine.ClassSubtype",
      "scale" => 0.4,
      "line" => { 4 => { "width" => 3 } }
    },
    "cableways" => {
      "from" => "Cableway_1",
      "scale" => 0.4,
      "lookup" => "delivsdm:geodb.Cableway.ClassSubtype",
      "line" => {
        1 => { "width" => 2 },
        2 => { "width" => 2, "type" => "dash_dot" }
      }
    },
    "misc-perimeters" => {
      "from" => "GeneralCulturalLine_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalLine.classsubtype",
      "scale" => 0.15,
      "line" => { 3 => { "width" => 1, "type" => "dash" } }
    },
    "towers" => {
      "from" => "GeneralCulturalPoint_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.ClassSubtype",
      "marker" => { 7 => { "type" => "square", "width" => 0.5 } }
    },
    "mines" => {
      "from" => "GeneralCulturalPoint_1",
      "where" => "generalculturaltype = 11 OR generalculturaltype = 12",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.ClassSubtype",
      "truetypemarker" => { 4 => { "font" => "ESRI Cartography", "character" => 204, "fontsize" => 7, "angle" => rotation } }
    },
    "yards" => {
      "from" => "GeneralCulturalPoint_1",
      "where" => "ClassSubtype = 4",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.generalculturaltype",
      "marker" => { "6;9" => { "type" => "square", "width" => 0.7, "color" => "0,0,0", "outline" => "255,255,255" } }
    },
    "windmills" => {
      "from" => "GeneralCulturalPoint_1",
      "where" => "generalculturaltype = 8",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.ClassSubtype",
      "truetypemarker" => { 4 => { "font" => "ESRI Default Marker", "character" => 69, "angle" => 45 + rotation, "fontsize" => 3 } }
    },
    "beacons" => {
      "from" => "GeneralCulturalPoint_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.ClassSubtype",
      "truetypemarker" => { 12 => { "font" => "ESRI Cartography", "character" => 208, "fontsize" => 7, "angle" => rotation } }
    },
    "railways" => {
      "scale" => 0.35,
      "from" => "Railway_1",
      "lookup" => "delivsdm:geodb.Railway.classsubtype",
      "hashline" => {
        "1;4" => { "width" => 6, "linethickness" => 3, "tickthickness" => 2, "interval" => 12 },
        "2;3" => { "width" => 4, "linethickness" => 2, "tickthickness" => 2, "interval" => 12 }
      }
    },
    "pipelines" => {
      "from" => "PipeLine_1",
      "line" => { "width" => 1 },
      "lookup" => "delivsdm:geodb.Pipeline.PosRelToGround",
      "line" => {
        "0;1;3" => { "width" => 1 },
        2 => { "width" => 1, "type" => "dash" }
      }
    },
    "transmission-lines" => {
      "scale" => 0.7,
      "from" => "ElectricityTransmissionLine_1",
      "line" => { "width" => 1, "type" => "dash_dot" }
    },
    "landing-grounds" => {
      "scale" => 1.0,
      "from" => "Runway_1",
      "lookup" => "delivsdm:geodb.Runway.runwaydefinition",
      "line" => {
        1 => { "width" => 1 },
        2 => { "width" => 5 },
        3 => { "width" => 0.5 }
      }
    },
    "gates-grids" => {
      "from" => "TrafficControlDevice_1",
      "lookup" => "delivsdm:geodb.TrafficControlDevice.ClassSubtype",
      "truetypemarker" => {
        1 => { "font" => "ESRI Geometric Symbols", "fontsize" => 3, "character" => 178, "angle" => rotation }, # gate
        2 => { "font" => "ESRI Geometric Symbols", "fontsize" => 3, "character" => 177, "angle" => rotation }  # grid
      }
    },
    "wharves" => {
      "from" => "TransportFacilityLine_1",
      "lookup" => "delivsdm:geodb.TransportFacilityLine.classsubtype",
      "scale" => 0.4,
      "line" => { 3 => { "width" => 3 } }
    },
  },
  cad_portlet => {
    "cadastre" => {
      "from" => "Lot_1",
      "line" => { "width" => 1 }
    },
    "trig-points" => {
      "from" => "SurveyMarks_1",
      "lookup" => "delivsdm:geodb.SurveyMark.ClassSubtype",
      "truetypemarker" => { 1 => { "font" => "ESRI Geometric Symbols", "fontsize" => 6, "character" => 180, "angle" => rotation } }
    },
  },
  act_heritage => {
    "act-rivers-and-creeks" => {
      "from" => 30,
      "lookup" => "PEREN_TEXT",
      "line" => {
        "Water Feature contains water infrequently" => { "width" => 1 },
        "Water Feature contains water frequently" => { "width" => 2 }
      }
    },
    "act-cadastre" => {
      "from" => 27,
      "line" => { "width" => 1 }
    },
    "act-urban-land" => {
      "from" => 71,
      "polygon" => { }
    },
    "act-lakes-and-major-rivers" => {
      "from" => 28,
      "polygon" => { }
    },
    "act-plantations" => {
      "from" => 51,
      "polygon" => { }
    },
    "act-roads-sealed" => [
      {
        "scale" => 0.4,
        "from" => 42,
        "lookup" => "RTYPE_TEXT",
        "line" => {
          "MAIN ROAD" => { "width" => 7, "captype" => "round" },
          "LOCAL CONNECTOR ROAD" => { "width" => 5, "captype" => "round" },
          "SEALED ROAD" => { "width" => 3, "captype" => "round" }
        }
      },
      {
        "scale" => 0.4,
        "from" => 67,
        "lookup" => "RTYPE_TEXT",
        "line" => { "HIGHWAY" => { "width" => 7, "captype" => "round" } }
      }
    ],
    "act-roads-unsealed" => {
      "scale" => 0.4,
      "from" => 42,
      "lookup" => "RTYPE_TEXT",
      "line" => {
        "UNSEALED ROAD" => { "width" => 3, "captype" => "round" }
      }
    },
    "act-vehicular-tracks" => {
      "scale" => 0.6,
      "from" => 42,
      "lookup" => "RTYPE_TEXT",
      "line" => {
        "VEHICULAR TRACK" => { "width" => 2, "type" => "dash", "captype" => "round" }
      },
    },
    "act-border" => {
      "scale" => 0.5,
      "from" => 3,
      "line" => { "width" => 2, "type" => "dash_dot_dot" }
    }
  },
  act_dog => {
    "act-adhoc-fire-access" => {
      "from" => 39,
      "scale" => 0.4,
      "lookup" => "STANDARD",
      "line" => { "Adhoc" => { "width" => 2, "type" => "dash", "captype" => "round" } }
    }
  },
  declination_service => {
    "declination" => { }
  },
  control_service => {
    "control-labels" => { "name" => "control-labels" },
    "control-circles" => { "name" => "control-circles" },
    "waterdrops" => { "name" => "waterdrops" },
  },
  lpi_ortho => {
    "aerial-lpi-ads40" => { "config" => "/ADS40ImagesConfig.js" },
    "aerial-lpi-sydney" => { "config" => "/SydneyImagesConfig.js" },
    "aerial-lpi-towns" => { "config" => "/NSWRegionalCentresConfig.js" },
    "aerial-lpi-eastcoast" => { "image" => "/Imagery/lr94ortho1m.ecw" }
  },
  google_maps => {
    "aerial-google" => { "name" => "satellite", "format" => "jpg" }
  },
  nokia_maps => {
    "aerial-nokia" => { "name" => 1, "format" => 1 }
  },
  oneearth_relief => [ config["relief"]["azimuth"] ].flatten.map do |azimuth|
    { "shaded-relief-#{azimuth}" => { "name" => "shaded-relief", "azimuth" => azimuth } }
  end.inject(:merge).merge(
    "elevation" => { "name" => "color-relief" }
  ),
}

bounds.inject(:product).map { |corner| UTMGridService.zone(projection, corner) }.uniq.each do |zone|
  grid_service = UTMGridService.new({ "zone" => zone }.merge config["grid"])
  services.merge!(grid_service => {
    "utm-#{zone}-grid" => { "name" => "grid" },
    "utm-#{zone}-eastings" => { "name" => "eastings" },
    "utm-#{zone}-northings" => { "name" => "northings" }
  })
end

puts "Final map size:"
puts "  scale: 1:%i" % scaling.scale
puts "  rotation: %.1f degrees" % rotation
puts "  %imm x %imm @ %i ppi" % [ *dimensions.map { |dimension| dimension * 25.4 / scaling.ppi }, scaling.ppi ]
puts "  %.1f megapixels (%i x %i)" % [ 0.000001 * dimensions.inject(:*), *dimensions ]

services.each do |service, layers|
  layers.reject do |label, options|
    config["exclude"].include? label
  end.each do |label, options|
    begin
      output_path = File.join(output_dir, "#{label}.png")
      unless File.exists?(output_path)
        Dir.mktmpdir do |temp_dir|
          dataset = service.dataset(bounds, projection, scaling, label, options, temp_dir)
          if dataset
            working_path = File.join(temp_dir, "layer.tif")
            canvas_path = File.join(temp_dir, "canvas.tif")
            
            puts "  assembling..."
            %x[convert -size #{dimensions.join 'x'} -units PixelsPerInch -density #{scaling.ppi} canvas:black -type TrueColor -depth 8 "#{canvas_path}"]
            %x[geotifcp -c lzw -e "#{world_file_path}" -4 "#{projection}" "#{canvas_path}" "#{working_path}"]
            
            unless dataset.empty?
              dataset_paths = dataset.collect do |tile_bounds, resolution, path|
                topleft = [ tile_bounds.first.min, tile_bounds.last.max ]
                write_world_file(topleft, resolution, 0, "#{path}w")
                %Q["#{path}"]
              end
              
              resample = service.params["resample"] || "cubic"
              vrt_path = File.join(temp_dir, "#{label}.vrt")
              %x[gdalbuildvrt "#{vrt_path}" #{dataset_paths.join " "}]
              %x[gdalwarp -s_srs "#{service.projection}" -dstalpha -r #{resample} "#{vrt_path}" "#{working_path}"]
            end
          
            if service.respond_to? :post_process
              puts "  processing..."
              service.post_process(working_path, centre, projection, dimensions, scaling, rotation, options)
            end
        
            %x[convert -quiet "#{working_path}" "#{output_path}"]
          end
        end
      end
    rescue InternetError, BadLayer => e
      puts
      puts "  skipping layer; error: #{e.message}"
    end
  end
end

formats_paths = config["formats"].map do |format|
  [ format, File.join(output_dir, "#{map_name}.#{format}") ]
end.reject do |format, path|
  File.exists? path
end
unless formats_paths.empty?
  puts "Building composite files:"
  Dir.mktmpdir do |temp_dir|
    puts "  generating patterns..."

    swamp = %w[
      00000100000
      00000100000
      00100100000
      00100100010
      00010100100
      00010100100
      00010101000
      01001101000
      00101110011
      00011111100
      11111111111
    ].map { |line| line.split("").join(",") }.join(" ")

    inundation_tile_path = File.join(temp_dir, "tile-inundation.tif");
    swamp_wet_tile_path = File.join(temp_dir, "tile-swamp-wet.tif");
    swamp_dry_tile_path = File.join(temp_dir, "tile-swamp-dry.tif");
    rock_area_tile_path = File.join(temp_dir, "tile-rock-area.tif");
    
    %x[convert -size 480x480 -virtual-pixel tile canvas: -fx "j%12==0" #{OP} +clone +noise Random -blur 0x2 -threshold 50% #{CP} -compose Multiply -composite "#{inundation_tile_path}"]
    %x[convert -size 480x480 -virtual-pixel tile canvas: -fx "j%12==7" #{OP} +clone +noise Random -threshold 88% #{CP} -compose Multiply -composite -morphology Dilate "11: #{swamp}" "#{inundation_tile_path}" -compose Plus -composite "#{swamp_wet_tile_path}"]
    %x[convert -size 480x480 -virtual-pixel tile canvas: -fx "j%12==7" #{OP} +clone +noise Random -threshold 88% #{CP} -compose Multiply -composite -morphology Dilate "11: #{swamp}" "#{inundation_tile_path}" -compose Plus -composite "#{swamp_dry_tile_path}"]
    %x[convert -size 400x400 -virtual-pixel tile canvas: +noise Random -blur 0x1 -modulate 100,1,100 -auto-level -ordered-dither threshold,4 +level 70%,95% "#{rock_area_tile_path}"]
    
    config["patterns"].each do |label, string|
      if File.exists?(string)
        tile_path = string
      elsif File.exists?(File.join(output_dir, string))
        tile_path = File.join(output_dir, string)
      else
        tile_path = File.join(temp_dir, "tile-#{label}.tif")
        tile = string.split(" ").map { |line| line.split(line[/,/] ? "," : "").map { |number| number.to_f } }
        abort("Error: fill pattern for '#{label}' must be rectangular") unless tile.map { |line| line.length }.uniq.length == 1
        maximum = tile.flatten.max
        tile.map! { |row| row.map { |number| number / maximum } }
        size = "#{tile.first.length}x#{tile.length}"
        kernel = "#{size}: #{tile.map { |row| row.join "," }.join " "}"
        %x[convert -size #{size} -virtual-pixel tile canvas: -fx "(i==0)&&(j==0)" -morphology Convolve "#{kernel}" "#{tile_path}"]
      end
    end
    
    puts "  preparing layers..."
    layers = [
      "aerial-google",
      "aerial-nokia",
      "aerial-lpi-sydney",
      "aerial-lpi-eastcoast",
      "aerial-lpi-towns",
      "aerial-lpi-ads40",
      "vegetation",
      "rock-area",
      "pine",
      "orchards-plantations",
      "built-up-areas",
      "contours",
      "ancillary-contours",
      "swamp-wet",
      "swamp-dry",
      "sand",
      "inundation",
      "cliffs",
      "cadastre",
      "act-cadastre",
      "watercourses",
      "ocean",
      "dams",
      "water-tanks",
      "water-areas-intermittent",
      "water-areas-intermittent-boundaries",
      "water-areas",
      "water-area-boundaries",
      "intertidal",
      "reef",
      "clifftops",
      "rocks-pinnacles",
      "misc-perimeters",
      "excavation",
      "coastline",
      "dam-walls",
      "wharves",
      "pipelines",
      "act-border",
      "pathways",
      "bridges-culverts",
      "floodways",
      "tracks-4wd",
      "tracks-vehicular",
      "roads-unsealed",
      "roads-sealed",
      "cableways",
      "gates-grids",
      "railways",
      "landing-grounds",
      "transmission-lines",
      "buildings",
      "building-areas",
      "caves",
      "towers",
      "windmills",
      "beacons",
      "mines",
      "yards",
      "trig-points",
      "labels",
      "waterdrops",
      "control-circles",
      "control-labels",
      "declination",
      "utm-54-grid",
      "utm-54-eastings",
      "utm-54-northings",
      "utm-55-grid",
      "utm-55-eastings",
      "utm-55-northings",
      "utm-56-grid",
      "utm-56-eastings",
      "utm-56-northings"
    ].reject do |label|
      config["exclude"].include? label
    end.map do |label|
      [ label, File.join(output_dir, "#{label}.png") ]
    end.select do |label, path|
      File.exists? path
    end.reject do |label, path|
      %x[convert -quiet "#{path}" -format "%[max]" info:].to_i == 0
    end.with_progress.map do |label, path|
      layer_path = File.join(temp_dir, "#{label}.tif")
      tile_path = File.join(temp_dir, "tile-#{label}.tif")
      colour = config["colours"][label]
      sequence = case
      when File.exist?(tile_path)
        if colour
          %Q[-alpha Copy #{OP} +clone -tile "#{tile_path}" -draw "color 0,0 reset" -background "#{colour}" -alpha Shape #{CP} -compose In -composite]
        else
          %Q[-alpha Copy #{OP} +clone -tile "#{tile_path}" -draw "color 0,0 reset" #{CP} -compose In -composite]
        end
      when colour
        %Q[-background "#{colour}" -alpha Shape]
      else
        ""
      end
      if config["glow"][label]
        glow = { "colour" => "white", "radius" => 0.15, "amount" => 80, "gamma" => 1 }
        glow.merge! config["glow"][label] if config["glow"][label].is_a? Hash
        colour, radius, amount, gamma = glow.values_at("colour", "radius", "amount", "gamma")
        sigma = radius * scaling.ppi / 25.4
        sequence += %Q[ #{OP} +clone -alpha Extract -blur 0x#{sigma} -normalize +level 0%,#{amount}% -background "#{colour}" -alpha Shape #{CP} -compose dst-over -composite]
      end
      %x[convert "#{path}" #{sequence} -type TrueColorMatte -depth 8 "#{layer_path}"]
      [ label, layer_path ]
    end
    
    flattened, layered = [ " -flatten", "" ].map do |compose|
      layers.map do |label, layer_path|
        %Q[#{OP} "#{layer_path}" -set label #{label} #{CP}#{compose}]
      end.join " "
    end
    
    formats_paths.each do |format, path|
      temp_path = File.join(temp_dir, "composite.#{format}")
      puts "  compositing #{map_name}.#{format}"
      sequence = case format.downcase
      when "psd" then "#{flattened} #{layered}"
      when /layer/ then layered
      else "#{flattened} -type TrueColor"
      end
      %x[convert -quiet #{sequence} "#{temp_path}"]
      if format[/tif/i]
        %x[geotifcp -e "#{world_file_path}" -4 "#{projection}" "#{temp_path}" "#{path}"]
      else
        FileUtils.mv(temp_path, path)
      end
    end
  end
end

oziexplorer_formats = [ "bmp", "png", "gif" ] & config["formats"]
unless oziexplorer_formats.empty?
  oziexplorer_path = File.join(output_dir, "#{map_name}.map")
  image_file = "#{map_name}.#{oziexplorer_formats.first}"
  image_path = File.join(output_dir, image_file)
  corners = dimensions.map do |dimension|
    [ -0.5 * dimension * scaling.metres_per_pixel, 0.5 * dimension * scaling.metres_per_pixel ]
  end.inject(:product).map do |offsets|
    [ centre, offsets.rotate(rotation * Math::PI / 180.0) ].transpose.map { |coord, offset| coord + offset }
  end
  wgs84_corners = corners.reproject(projection, WGS84).values_at(1,3,2,0)
  pixel_corners = [ dimensions, [ :to_a, :reverse ] ].transpose.map { |dimension, order| [ 0, dimension ].send(order) }.inject(:product).values_at(1,3,2,0)
  calibration_strings = [ pixel_corners, wgs84_corners ].transpose.map.with_index do |(pixel_corner, wgs84_corner), index|
    dmh = [ wgs84_corner, [ [ ?E, ?W ], [ ?N, ?S ] ] ].transpose.reverse.map do |coord, hemispheres|
      [ coord.abs.floor, 60 * (coord.abs - coord.abs.floor), coord > 0 ? hemispheres.first : hemispheres.last ]
    end
    "Point%02i,xy,%i,%i,in,deg,%i,%f,%c,%i,%f,%c,grid,,,," % [ index+1, pixel_corner, dmh ].flatten
  end
  File.open(oziexplorer_path, "w") do |file|
    file << %Q[OziExplorer Map Data File Version 2.2
#{image_file}
#{image_path}
1 ,Map Code,
WGS 84,WGS84,0.0000,0.0000,WGS84
Reserved 1
Reserved 2
Magnetic Variation,,,E
Map Projection,Transverse Mercator,PolyCal,No,AutoCalOnly,Yes,BSBUseWPX,No
#{calibration_strings.join("\n")}
Projection Setup,0.000000000,#{projection_centre.first},0.999600000,500000.00,10000000.00,,,,,
Map Feature = MF ; Map Comment = MC     These follow if they exist
Track File = TF      These follow if they exist
Moving Map Parameters = MM?    These follow if they exist
MM0,Yes
MMPNUM,4
#{pixel_corners.map.with_index { |pixel_corner, index| "MMPXY,#{index+1},#{pixel_corner.join(",")}" }.join("\n")}
#{wgs84_corners.map.with_index { |wgs84_corner, index| "MMPLL,#{index+1},#{wgs84_corner.join(",")}" }.join("\n")}
MM1B,#{scaling.metres_per_pixel}
MOP,Map Open Position,0,0
IWH,Map Image Width/Height,#{dimensions.join(",")}
]
  end
end

# TODO: replace all simple markers with truetype markers to allow rotation?
# TODO: (alternatively, don't rotate any symbols or labels at all...)
# TODO: access missing content (FuzzyExtentPoint, SpotHeight, AncillaryHydroPoint, PointOfInterest, RelativeHeight, ClassifiedFireTrail, PlacePoint, PlaceArea) via workspace name?

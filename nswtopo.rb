#!/usr/bin/env ruby

require 'uri'
require 'net/http'
require 'rexml/document'
require 'tmpdir'
require 'tempfile'
require 'yaml'
require 'erb'

EARTH_RADIUS = 6378137.0

class REXML::Element
  alias_method :unadorned_add_element, :add_element
  def add_element(name, attrs = {})
    result = unadorned_add_element(name, attrs)
    yield result if block_given?
    result
  end
end

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
      $stderr.puts e.message and return nil
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

def transform_coordinates(source_projection, target_projection, *source_coords)
  source_string = source_coords.map { |coords| coords.join " " }.join "\n"
  target_string = %x[echo "#{source_string}" | gdaltransform -s_srs "#{source_projection}" -t_srs "#{target_projection}"]
  target_coords = target_string.split("\n").map { |triplet| triplet.split(" ")[0..1].map { |number| number.to_f } }
  source_coords.length > 1 ? target_coords : target_coords.flatten
end

def bounds_to_corners(bounds)
  [ bounds.first, bounds.last ].transpose + [ bounds.first.reverse, bounds.last ].transpose
end

def corners_to_bounds(corners)
  [ [ corners.transpose.first.min, corners.transpose.first.max ], [ corners.transpose.last.min, corners.transpose.last.max ] ]
end

def transform_bounds(source_projection, target_projection, bounds)
  corners_to_bounds(transform_coordinates(source_projection, target_projection, *bounds_to_corners(bounds)))
end

def write_world_file(topleft, resolution, path)
  File.open(path, "w") do |file|
    file.puts  resolution
    file.puts  0.0
    file.puts  0.0
    file.puts -resolution
    file.puts topleft.first + 0.5 * resolution
    file.puts topleft.last - 0.5 * resolution
  end
end

class Scaling
  def initialize(scale, ppi)
    @ppi = ppi
    @metres_per_pixel = scale * 0.0254 / ppi
  end
  
  attr_reader :ppi, :metres_per_pixel
end

class Service
  def initialize(params)
    @params = params
    @projection = params["projection"]
  end
  
  def data?(input_bounds, input_projection)
    return true unless params["envelope"]
    projected_bounds = transform_bounds(input_projection, params["envelope"]["projection"], input_bounds)
    return [ projected_bounds, params["envelope"]["bounds"] ].transpose.map do |projected_bound, envelope_bound|
      projected_bound.max > envelope_bound.min && projected_bound.min < envelope_bound.max
    end.inject(:&)
  end
  
  attr_reader :projection, :params
end

class ArcIMS < Service
  def tiles(input_bounds, input_projection, scaling)
    tile_sizes = params["tile_sizes"]
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
  
  def dataset(input_bounds, input_projection, scaling, options_or_array, dir)
    options_array = [ options_or_array ].flatten
    
    scales = options_array.map { |options| options["scale"] }.compact.uniq
    abort("more than one scale specified") if scales.length > 1
    dpi = scales.any? ? (scales.first * scaling.ppi).round : 96
    
    tiles(input_bounds, input_projection, scaling).each_with_index.map do |(bounds, extents), tile_index|
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
                  renderer_attributes.merge! options["label"].reject { |k, v| k == "field" } if options["label"]
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
                        attrs["boundarywidth"] ||= 2 if attrs["antialiasing"]
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
                            renderer.add_element("EXACT", "value" => value) do |exact|
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
        xml = REXML::Document.new(post_response.body)
        abort(xml.elements["ARCXML"].elements["RESPONSE"].elements["ERROR"].text) if xml.elements["ARCXML"].elements["RESPONSE"].elements["ERROR"]
        get_uri = URI.parse xml.elements["ARCXML"].elements["RESPONSE"].elements["IMAGE"].elements["OUTPUT"].attributes["url"]
        http_get(get_uri, "retries" => 5) do |get_response|
          File.open(tile_path, "w") { |file| file << get_response.body }
        end
      end
      sleep(params["interval"]) if params["interval"]
      
      [ bounds, scaling.metres_per_pixel, tile_path ]
    end
  end
end

class TiledMapService < Service
  def dataset(input_bounds, input_projection, scaling, options, dir)
    tile_sizes = params["tile_sizes"]
    crops = params["crops"] || [ [ 0, 0 ], [ 0, 0 ] ]
    bounds = transform_bounds(input_projection, projection, input_bounds)
    origins = bounds.transpose.first
    zoom = (Math::log2(Math::PI * EARTH_RADIUS / scaling.metres_per_pixel) - 7 - 0.5).ceil
    metres_per_pixel = Math::PI * EARTH_RADIUS / 2 ** (zoom + 7)
    
    extents = bounds.map { |bound| bound.max - bound.min }
    cropped_tile_sizes = [ tile_sizes, crops ].transpose.map { |tile_size, crop| tile_size - crop.inject(:+) }
    counts = [ extents, cropped_tile_sizes ].transpose.map { |extent, tile_size| (extent / metres_per_pixel / tile_size).ceil }
    
    format = options["format"]
    name = options["name"]
    
    puts "    (downloading #{counts.inject(:*)} tiles)"
    
    counts.map { |count| (0...count).to_a }.inject(:product).map do |indices|
      sleep(params["interval"] || 0)
      tile_path = File.join(dir, "tile.#{indices.join('.')}.png")
      
      cropped_centre = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
        origin + tile_size * (index + 0.5) * metres_per_pixel
      end
      centre = [ cropped_centre, crops ].transpose.map { |coord, crop| coord - 0.5 * crop.inject(:-) * metres_per_pixel }
      bounds = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
        [ origin + index * tile_size * metres_per_pixel, origin + (index + 1) * tile_size * metres_per_pixel ]
      end
      
      longitude, latitude = transform_coordinates(projection, "EPSG:4326", centre)
      
      attributes = [ "longitude", "latitude", "zoom", "format", "hsize", "vsize", "name" ]
      values     = [  longitude,   latitude,   zoom,   format,      *tile_sizes,   name  ]
      uri_string = [ attributes, values ].transpose.inject(params["uri"]) do |string, array|
        attribute, value = array
        string.gsub(Regexp.new("\\$\\{#{attribute}\\}"), value.to_s)
      end
      uri = URI.parse(uri_string)
      
      http_get(uri, "retries" => 5) do |response|
        File.open(tile_path, "w") { |file| file << response.body }
        %x[mogrify -quiet -type TrueColor -depth 8 -format png -define png:color-type=2 #{tile_path}]
        %x[mogrify -quiet -crop #{cropped_tile_sizes.join "x"}+#{crops.first.first}+#{crops.last.last} #{tile_path}]
        [ bounds, metres_per_pixel, tile_path ]
      end
    end.compact
  end
end

class OneEarthDEMRelief < Service
  def initialize(params)
    super(params)
    @projection = "EPSG:4326"
  end
  
  def dataset(input_bounds, input_projection, scaling, options, dir)
    bounds = transform_bounds(input_projection, projection, input_bounds)
    bounds = bounds.map { |bound| [ ((bound.first - 0.01) / 0.125).floor * 0.125, ((bound.last + 0.01) / 0.125).ceil * 0.125 ] }
    counts = bounds.map { |bound| ((bound.max - bound.min) / 0.125).ceil }
    units_per_pixel = 0.125 / 300
    
    [ counts, bounds ].transpose.map do |count, bound|
      boundaries = (0..count).map { |index| bound.first + index * 0.125 }
      [ boundaries[0..-2], boundaries[1..-1] ].transpose
    end.inject(:product).each_with_index do |tile_bounds, index|
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
      }.map { |key, value| "#{key}=#{value}" }.join("&")
      uri = URI::HTTP.build :host => "onearth.jpl.nasa.gov", :path => "/wms.cgi", :query => URI.escape(query)

      http_get(uri, "retries" => 5) do |response|
        File.open(tile_path, "w") { |file| file << response.body }
        write_world_file([ tile_bounds.first.min, tile_bounds.last.max ], units_per_pixel, "#{tile_path}w")
        sleep(params["interval"] || 0)
      end
    end
    vrt_path = File.join(dir, "dem.vrt")
    wildcard_path = File.join(dir, "*.png")
    relief_path = File.join(dir, "output.tif")
    output_path = File.join(dir, "output.png")
    %x[gdalbuildvrt #{vrt_path} #{wildcard_path}]
    case options["name"]
    when "hillshade"
      altitude = params["altitude"] || 45
      azimuth = params["azimuth"] || 315
      exaggeration = params["exaggeration"] || 1
      %x[gdaldem hillshade -s 111120 -alt #{altitude} -z #{exaggeration} -az #{azimuth} #{vrt_path} #{relief_path} -q]
    when "color-relief"
      colours = params["colours"] || { "0%" => "black", "100%" => "white" }
      colour_path = File.join(dir, "colours")
      File.open(colour_path, "w") do |file|
        colours.each { |elevation, colour| file.puts "#{elevation} #{colour}" }
      end
      %x[gdaldem color-relief #{vrt_path} #{colour_path} #{relief_path} -q]
    end
    %x[convert #{relief_path} -quiet -type TrueColor -depth 8 -format png -define png:color-type=2 #{output_path}]
    
    [ [ bounds, units_per_pixel, output_path ] ]
  end
end

class AnnotationService < Service
  def dataset(input_bounds, input_projection, scaling, options, dir)
    # TODO: this is wrong if the projection is not a UTM grid!
    bounds = transform_bounds(input_projection, projection, input_bounds)
    extents = bounds.map { |bound| bound.max - bound.min }
    pixels = extents.map { |extent| (extent / scaling.metres_per_pixel).ceil }
    tile_path = File.join(dir, "tile.0.png") # just one big tile
    draw_string = draw(bounds, extents, scaling, options);
    %x[convert -units PixelsPerInch -density #{scaling.ppi} -size #{pixels.join 'x'} canvas:black -type TrueColor -define png:color-type=2 -depth 8 #{draw_string} #{tile_path}]
    [ [ bounds, scaling.metres_per_pixel, tile_path ] ]
  end
end

class GridService < AnnotationService
  def draw(bounds, extents, scaling, options)
    intervals = params["intervals"]
    fontsize = params["fontsize"] || 4.5
    
    indices = [ bounds, intervals ].transpose.map do |bound, interval|
      ((bound.first / interval).floor .. (bound.last / interval).ceil).to_a
    end
    tick_coords = [ indices, intervals ].transpose.map { |range, interval| range.map { |index| index * interval } }
    tick_pixels = [ tick_coords, bounds, extents, [ 0, 1 ], [ 1, -1 ] ].transpose.map do |coords, bound, extent, index, sign|
      coords.map { |coord| ((coord - bound[index]) * sign / scaling.metres_per_pixel).round }
    end
    
    centre_coords = bounds.map { |bound| 0.5 * bound.inject(:+) }
    centre_indices = [ centre_coords, indices, intervals ].transpose.map do |coord, range, interval|
      range.index((coord / interval).round)
    end
    
    case options["name"]
    when "grid"
      commands = [ "-draw 'line %d,0 %d,#{extents.last}'", "-draw 'line 0,%d #{extents.first},%d'" ]
      string = [ tick_pixels, commands ].transpose.map { |pixelz, command| pixelz.map { |pixel| command % [ pixel, pixel ] }.join " "}.join " "
      "-stroke white -strokewidth 1 #{string}"
    when "eastings"
      centre_pixel = tick_pixels.last[centre_indices.last]
      dx, dy = [ 0.04 * scaling.ppi ] * 2
      string = [ tick_pixels, tick_coords ].transpose.first.transpose.map { |pixel, tick| "-draw \"translate #{pixel-dx},#{centre_pixel-dy} rotate -90 text 0,0 '#{tick}'\"" }.join " "
      "-fill white -pointsize #{fontsize} -family 'Arial Narrow' -weight 100 #{string}"
    when "northings"
      centre_pixel = tick_pixels.first[centre_indices.first]
      dx, dy = [ 0.04 * scaling.ppi ] * 2
      string = [ tick_pixels, tick_coords ].transpose.last.transpose.map { |pixel, tick| "-draw \"text #{centre_pixel+dx},#{pixel-dy} '#{tick}'\"" }.join " "
      "-fill white -pointsize #{fontsize} -family 'Arial Narrow' -weight 100 #{string}"
    end
  end
end

class DeclinationService < AnnotationService
  def draw(bounds, extents, scaling, options)
    spacing = params["spacing"]
    angle = params["angle"]
    
    radians = angle * Math::PI / 180.0
    x_spacing = spacing / Math::cos(radians) / scaling.metres_per_pixel
    dx = extents.last * Math::tan(radians)
    x_min = [ 0, dx ].min
    x_max = [ extents.first, extents.first + dx ].max
    line_count = (x_max - x_min) / x_spacing
    x_starts = (1..line_count).map { |n| x_min + n * x_spacing }
    string = x_starts.map { |x| "-draw 'line #{x.to_i},0 #{(x - dx).to_i},#{extents.last}'" }.join " "
    "-stroke white -strokewidth 1 #{string}"
  end
end

class ControlService < AnnotationService
  def data?(input_bounds, input_projection)
    return File.exists?(params["gpx_path"])
  end
  
  def draw(bounds, extents, scaling, options)
    xml = REXML::Document.new(File.open params["gpx_path"])
    waypoints = xml.elements["gpx"].elements.collect("wpt") do |element|
      [ element.attributes["lon"].to_f, element.attributes["lat"].to_f ]
    end
    numbers = xml.elements["gpx"].elements.collect("wpt") do |element|
      element.elements["name"].text
    end
    
    radius = params["diameter"] * scaling.ppi / 25.4 / 2
    strokewidth = params["thickness"] * scaling.ppi / 25.4
    string = [ transform_coordinates("EPSG:4326", projection, *waypoints), numbers ].transpose.map do |coordinates, number|
      x = (coordinates.first - bounds.first.min) / scaling.metres_per_pixel
      y = (bounds.last.max - coordinates.last) / scaling.metres_per_pixel
      case options["name"]
      when "circles"
        if number == "HH"
          "-draw 'polygon #{x},#{y - radius} #{x + radius * Math::sqrt(0.75)},#{y + radius * 0.5}, #{x - radius * Math::sqrt(0.75)},#{y + radius * 0.5}'"
        else
          "-draw 'circle #{x},#{y} #{x + radius},#{y}'"
        end
      when "numbers"
        "-draw \"text #{x + radius},#{y - radius} '#{number}'\""
      end
    end.join " "
    
    case options["name"]
    when "circles"
      "-stroke white -strokewidth #{strokewidth} #{string}"
    when "numbers"
      "-fill white -pointsize #{params['fontsize']} -family 'Arial' -weight Normal #{string}"
    end
  end
end

output_dir = Dir.pwd
config = YAML.load(File.open(File.join(output_dir, "config.yml")))
map_name = config["name"] || "map"
tfw_path = File.join(output_dir, "#{map_name}.tfw")
proj_path = File.join(output_dir, "#{map_name}.prj")

if config["easting"] && config["northing"] && config["zone"]
  input_projection = "+proj=utm +zone=#{config["zone"]} +south +datum=WGS84"
  input_bounds = [ config["easting"].values.sort, config["northing"].values.sort ]
elsif config["latitude"] && config["longitude"]
  input_projection = "EPSG:4326"
  input_bounds = [ config["longitude"].values.sort, config["latitude"].values.sort ]
else
  abort("Error: must provide map bounds in UTM or WGS84.")
end

scaling = Scaling.new(config["scale"], config["ppi"])

central_meridian, central_latitude = transform_coordinates(input_projection, "EPSG:4326", input_bounds.map { |bound| 0.5 * bound.inject(:+) })
target_projection = "+proj=tmerc +lat_0=0.000000000 +lon_0=#{central_meridian} +k=0.999600 +x_0=500000.000 +y_0=10000000.000 +ellps=WGS84 +datum=WGS84 +units=m"
target_wkt = %Q{PROJCS["BLAH",GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.017453292519943295]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",500000.0],PARAMETER["False_Northing",10000000.0],PARAMETER["Central_Meridian",#{central_meridian}],PARAMETER["Scale_Factor",0.9996],PARAMETER["Latitude_Of_Origin",0.0],UNIT["Meter",1.0]]}
nearest_utm = "+proj=utm +zone=#{central_meridian > 150.0 ? 56 : 55} +south +datum=WGS84"
target_bounds = transform_bounds(input_projection, target_projection, input_bounds)
target_extents = target_bounds.map { |bound| ((bound.max - bound.min) / scaling.metres_per_pixel).ceil }
topleft = [ target_bounds.first.min, target_bounds.last.max ]
write_world_file(topleft, scaling.metres_per_pixel, tfw_path)
File.open(proj_path, "w") { |file| file.puts target_projection }

puts "Final map size:"
puts "  %.1fcm x %.1fcm @ %i ppi" % [ *target_extents.map { |extent| extent * 2.54 / scaling.ppi }, scaling.ppi ]
puts "  %.1f megapixels (%i x %i)" % [ 0.000001 * target_extents.inject(:*), *target_extents ]

topo_portlet = ArcIMS.new(
  "host" => "maps.nsw.gov.au",
  "path" => "/servlet/com.esri.esrimap.Esrimap",
  "name" => "topo_portlet",
  "projection" => target_projection,
  "wkt" => target_wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "envelope" => {
    "bounds" => [ [ 140.011127032369, 154.62466299763 ], [ -37.740334035, -27.924909045 ] ],
    "projection" => "EPSG:4283"
  })
cad_portlet = ArcIMS.new(
  "host" => "maps.nsw.gov.au",
  "path" => "/servlet/com.esri.esrimap.Esrimap",
  "name" => "cad_portlet",
  "projection" => target_projection,
  "wkt" => target_wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "envelope" => {
    "bounds" => [ [ 140.05983881892, 154.575951211079 ], [ -37.740334035, -27.924909045 ] ],
    "projection" => "EPSG:4283"
  })
act_heritage = ArcIMS.new(
  "host" => "www.gim.act.gov.au",
  "path" => "/arcims/ims",
  "name" => "Heritage",
  "projection" => target_projection,
  "wkt" => target_wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "envelope" => {
    "bounds" => [ [ 660000, 718000 ], [ 6020000, 6107000 ] ],
    "projection" => "EPSG:32755"
  })
act_dog = ArcIMS.new(
  "host" => "www.gim.act.gov.au",
  "path" => "/arcims/ims",
  "name" => "dog",
  "projection" => target_projection,
  "wkt" => target_wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "envelope" => {
    "bounds" => [ [ 659890.105040274, 720782.12808229 ], [ 6022931.0546655, 6111100.93973127 ] ],
    "projection" => "EPSG:32755"
  })
nokia_maps = TiledMapService.new(
  "uri" => "http://m.ovi.me/?c=${latitude},${longitude}&t=${name}&z=${zoom}&h=${vsize}&w=${hsize}&f=${format}&nord&nodot",
  "projection" => "EPSG:3857",
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.3,
  "crops" => [ [ 0, 0 ], [ 26, 0 ] ]
)
google_maps = TiledMapService.new(
  "uri" => "http://maps.googleapis.com/maps/api/staticmap?zoom=${zoom}&size=${hsize}x${vsize}&scale=1&format=${format}&maptype=${name}&sensor=false&center=${latitude},${longitude}",
  "projection" => "EPSG:3857",
  "tile_sizes" => [ 640, 640 ],
  "crops" => [ [ 0, 0 ], [ 30, 0 ] ],
  "interval" => 1
)
grid_service = GridService.new({
    "projection" => nearest_utm,
    "intervals" => [ 1000, 1000 ],
  }.merge(config["grid"] || {})
)
oneearth_relief = OneEarthDEMRelief.new({
    "interval" => 0.3
  }.merge(config["relief"] || {})
)
declination_service = DeclinationService.new({
    "projection" => target_projection,
    "spacing" => 1000,
  }.merge(config["declination"])
)
control_service = ControlService.new({
  "gpx_path" => File.join(output_dir, "controls.gpx"),
  "projection" => target_projection,
  "fontsize" => 14,
  "diameter" => 7,
  "thickness" => 0.2
  }.merge(config["controls"] || {})
)

services = {
  topo_portlet => {
    "contours-10m-50m" => [
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, 10) = 0",
        "line" => { "width" => 1 }
      },
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, 50) = 0",
        "line" => { "width" => 2 }
      },
    ],
    "contours-10m-100m" => [
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, 10) = 0",
        "line" => { "width" => 1 }
      },
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, 100) = 0",
        "line" => { "width" => 2 }
      },
    ],
    "contours-20m-100m" => [
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, 20) = 0",
        "line" => { "width" => 1 }
      },
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, 100) = 0",
        "line" => { "width" => 2 }
      },
    ],
    "labels-contours-50m" => {
      "from" => "Contour_1",
      "where" => "MOD(elevation, 50) = 0",
      "label" => { "field" => "delivsdm:geodb.Contour.Elevation", "linelabelposition" => "placeontop" },
      "text" => { "font" => "Arial", "fontsize" => 3.4 }
    },
    "labels-contours-100m" => {
      "from" => "Contour_1",
      "where" => "MOD(elevation, 100) = 0",
      "label" => { "field" => "delivsdm:geodb.Contour.Elevation", "linelabelposition" => "placeontop" },
      "text" => { "font" => "Arial", "fontsize" => 3.4 }
    },
    "watercourses" => {
      "from" => "HydroLine_1",
      "lookup" => "delivsdm:geodb.HydroLine.Perenniality",
      "line" => {
        1 => { "width" => 2 },
        2 => { "width" => 1 }
      }
    },
    "labels-watercourses" => {
      "from" => "HydroLine_Label_1",
      "lookup" => "delivsdm:geodb.HydroLine.Perenniality",
      "label" => { "field" => "delivsdm:geodb.HydroLine.HydroName delivsdm:geodb.HydroLine.HydroNameType", "linelabelposition" => "placeabove" },
      "text" => {
        1 => { "fontsize" => 4.0, "printmode" => "titlecaps", "fontstyle" => "italic" },
        2 => { "fontsize" => 2.8, "printmode" => "titlecaps", "fontstyle" => "italic" }
      }
    },
    "water-areas" => {
      "from" => "HydroArea_1",
      "polygon" => { "antialiasing" => true }
    },
    "labels-water-areas" => {
      "from" => "HydroArea_Label_1",
      "label" => { "field" => "delivsdm:geodb.HydroArea.HydroName delivsdm:geodb.HydroArea.HydroNameType" },
      "text" => { "fontsize" => 4, "printmode" => "titlecase" }
    },
    "roads-sealed" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "where" => "surface = 0 OR surface = 1",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => {
        "1;2;3" => { "width" => 7 },
        "4;5"   => { "width" => 5 },
        "6;7"   => { "width" => 3 }
      }
    },
    "roads-unsealed" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "where" => "surface != 0 AND surface != 1",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => {
        "1;2;3" => { "width" => 7 },
        "4;5"   => { "width" => 5 },
        "6;7"   => { "width" => 3 }
      }
    },
    "vehicular-tracks" => {
      "scale" => 0.6,
      "from" => "RoadSegment_1",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => { 8 => { "width" => 2, "type" => "dash" } },
    },
    "pathways" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => { 9 => { "width" => 2, "type" => "dash" } },
    },
    "labels-roads" => {
      "from" => "RoadSegment_Label_1",
      "lookup" => "delivsdm:geodb.RoadSegment.FunctionHierarchy",
      "label" => { "field" => "delivsdm:geodb.RoadSegment.RoadNameBase delivsdm:geodb.RoadSegment.RoadNameType delivsdm:geodb.RoadSegment.RoadNameSuffix" },
      "text" => {
        "1;2;3;4;5" => { "fontsize" => 4.5, "fontstyle" => "italic", "printmode" => "allupper" },
        "6;7;8" => { "fontsize" => 3.4, "fontstyle" => "italic", "printmode" => "allupper" },
      }
    },
    "buildings" => {
      "from" => "BuildingComplexPoint_1",
      "marker" => { "type" => "square", "width" => 0.6, "antialiasing" => false }
    },
    "labels-buildings" => {
      "from" => "BuildingComplexPoint_Label_1",
      "label" => { "field" => "delivsdm:geodb.BuildingComplexPoint.GeneralName" },
      "text" => { "font" => "Arial", "fontsize" => 3, "fontstyle" => "italic", "printmode" => "titlecaps", "interval" => 1.0 }
    },
    "dams" => {
      "from" => "HydroPoint_1",
      "lookup" => "delivsdm:geodb.HydroPoint.ClassSubtype",
      "marker" => { 1 => { "type" => "square", "width" => 0.8, "antialiasing" => false } }
    },
    "built-up-areas" => {
      "from" => "GeneralCulturalArea_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalArea.ClassSubtype",
      "polygon" => { 7 => { } }
    },
    "plantations" => {
      "from" => "GeneralCulturalArea_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalArea.ClassSubtype",
      "polygon" => { 6 => { } }
    },
    "building-areas" => {
      "from" => "GeneralCulturalArea_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalArea.ClassSubtype",
      "polygon" => { 5 => { } }
    },
    "vegetation" => {
      "image" => "Vegetation_1"
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
      "line" => { 1 => { "width" => 1, "type" => "dot", "antialiasing" => false } }
    },
    "excavation" => {
      "from" => "DLSLine_1",
      "lookup" => "delivsdm:geodb.DLSLine.ClassSubtype",
      "line" => { 3 => { "width" => 1, "type" => "dot", "antialiasing" => false } }
    },
    "caves" => {
      "from" => "DLSPoint_1",
      "lookup" => "delivsdm:geodb.DLSPoint.ClassSubtype",
      "truetypemarker" => { 1 => { "font" => "ESRI Caves 3", "fontsize" => 8, "character" => 47 } }
    },
    "labels-caves" => {
      "from" => "DLSPoint_Label_1",
      "lookup" => "delivsdm:geodb.DLSPoint.ClassSubtype",
      "label" => { "field" => "delivsdm:geodb.DLSPoint.GeneralName" },
      "text" => { 1 => { "font" => "Arial", "fontsize" => 3, "printmode" => "titlecaps", "interval" => 2.0 } }
    },
    "pinnacles" => {
      "from" => "DLSPoint_1",
      "lookup" => "delivsdm:geodb.DLSPoint.ClassSubtype",
      "truetypemarker" => { 2 => { "font" => "ESRI Default Marker", "character" => 107, "fontsize" => 3 } }
    },
    "ocean" => {
      "from" => "FuzzyExtentWaterArea_1",
      "polygon" => { }
    },
    "coastline" => {
      "from" => "Coastline_1",
      "line" => { "width" => 1 }
    },
    "labels-fuzzy-extent" => [
      {
        "from" => "FuzzyExtentArea_Label_1",
        "label" => { "field" => "delivsdm:geodb.FuzzyExtentArea.GeneralName" },
        "text" => { "font" => "Arial", "fontsize" => 4, "printmode" => "titlecaps" }
      },
      {
        "from" => "FuzzyExtentLine_Label_1",
        "label" => { "field" => "delivsdm:geodb.FuzzyExtentLine.GeneralName" },
        "text" => { "font" => "Arial", "fontsize" => 4, "printmode" => "titlecaps" }
      },
    ],
    "dam-walls" => {
      "from" => "GeneralCulturalLine_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalLine.ClassSubtype",
      "scale" => 0.4,
      "line" => { 4 => { "width" => 3 } }
    },
    "towers" => {
      "from" => "GeneralCulturalPoint_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.ClassSubtype",
      "truetypemarker" => { 7 => { "font" => "ESRI Cartography", "character" => 100, "fontsize" => 7 } }
    },
    "transmission-lines" => {
      "scale" => 0.7,
      "from" => "ElectricityTransmissionLine_1",
      "line" => { "width" => 1, "type" => "dash_dot" }
    },
    "railways" => {
      "scale" => 0.7,
      "from" => "Railway_1",
      "hashline" => { "width" => 3, "linethickness" => 1, "tickthickness" => 1, "interval" => 6 }
    },
    "runways" => {
      "scale" => 1.0,
      "from" => "Runway_1",
      "line" => { "width" => 3 }
    },
    "gates-grids" => {
      "from" => "TrafficControlDevice_1",
      "lookup" => "delivsdm:geodb.TrafficControlDevice.ClassSubtype",
      "truetypemarker" => {
        1 => { "font" => "ESRI Geometric Symbols", "fontsize" => 3, "character" => 178 },
        2 => { "font" => "ESRI Geometric Symbols", "fontsize" => 3, "character" => 177 }
      }
    },
  },
  cad_portlet => {
    "cadastre" => {
      "from" => "Address_1",
      "line" => { "width" => 1 }
    },
    "nsw-border" => {
      "scale" => 0.5,
      "from" => "Border_1",
      "line" => { "width" => 2, "type" => "dash_dot_dot" }
    }
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
      "polygon" => { "antialiasing" => true }
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
          "MAIN ROAD" => { "width" => 7 },
          "LOCAL CONNECTOR ROAD" => { "width" => 5 },
          "SEALED ROAD" => { "width" => 3 }
        }
      },
      {
        "scale" => 0.4,
        "from" => 67,
        "lookup" => "RTYPE_TEXT",
        "line" => { "HIGHWAY" => { "width" => 7 } }
      }
    ],
    "act-roads-unsealed" => {
      "scale" => 0.4,
      "from" => 42,
      "lookup" => "RTYPE_TEXT",
      "line" => {
        "UNSEALED ROAD" => { "width" => 3 }
      }
    },
    "act-vehicular-tracks" => {
      "scale" => 0.6,
      "from" => 42,
      "lookup" => "RTYPE_TEXT",
      "line" => {
        "VEHICULAR TRACK" => { "width" => 2, "type" => "dash" }
      },
    },
  },
  act_dog => {
    "act-adhoc-fire-access" => {
      "from" => 39,
      "scale" => 0.4,
      "lookup" => "STANDARD",
      "line" => { "Adhoc" => { "width" => 2, "type" => "dash" } }
    }
  },
  nokia_maps => {
    "aerial-nokia" => {
      "name" => 1,
      "format" => 1
    }
  },
  google_maps => {
    "aerial-google" => {
      "name" => "satellite",
      "format" => "jpg"
    }
  },
  grid_service => {
    "utm-grid" => { "name" => "grid" },
    "utm-eastings" => { "name" => "eastings" },
    "utm-northings" => { "name" => "northings" }
  },
  oneearth_relief => {
    "hillshade" => { "name" => "hillshade" },
    "colour-relief" => { "name" => "color-relief" }
  },
  declination_service => {
    "declination" => { }
  },
  control_service => {
    "control-numbers" => { "name" => "numbers" },
    "control-circles" => { "name" => "circles" }
  }
}

services.each do |service, layers|
  layers.each do |filename, options|
    output_path = File.join(output_dir, "#{filename}.tif")
    unless File.exists?(output_path) || !service.data?(target_bounds, target_projection)
      puts "Layer: #{filename}"
      Dir.mktmpdir do |temp_dir|
        canvas_path = File.join(temp_dir, "canvas.tif")
        vrt_path = File.join(temp_dir, "#{filename}.vrt")
        working_path = File.join(temp_dir, "#{filename}.tif")
        
        puts "  preparing..."
        %x[convert -quiet -size #{target_extents.join 'x'} canvas:black -type TrueColor -depth 8 #{canvas_path}]
        %x[geotifcp -c lzw -e #{tfw_path} -4 '#{target_projection}' #{canvas_path} #{working_path}]
        
        if service
          puts "  downloading..."
          dataset_path = service.dataset(target_bounds, target_projection, scaling, options, temp_dir).collect do |bounds, resolution, path|
            topleft = [ bounds.first.min, bounds.last.max ]
            write_world_file(topleft, resolution, "#{path}w")
            %x[mogrify -quiet -type TrueColor -depth 8 -format png -define png:color-type=2 #{path}]
            path
          end.join " "
          
          puts "  assembling..."
          %x[gdalbuildvrt #{vrt_path} #{dataset_path}]
          %x[gdalwarp -s_srs "#{service.projection}" -r cubic #{vrt_path} #{working_path}]
        end
        
        %x[mogrify -quiet -units PixelsPerInch -density #{scaling.ppi} -compress LZW #{working_path}]
        %x[geotifcp -e #{tfw_path} -4 '#{target_projection}' #{working_path} #{output_path}]
      end
    end
  end
end

sequences = {
  # "caves" => 
  # "cliffs" => 
  # "clifftops" => 
  # "coastline" => 
  # "excavation" => 
  # "hillshade" => 
  # "intertidal" => 
  # "inundation" => 
  # "labels-caves" => 
  # "nsw-border" => 
  # "pinnacles" => 
  # "reef" => 
  # "rock-area" => 
  
  "aerial-google" => { },
  "vegetation" => { },
  # "ocean" => 
  "built-up-areas" => { "color" => "#F8FF73" },
  # "plantations" => 
  "contours-10m-100m" => { "color" => "Dark Magenta" },
  "building-areas" => { "color" => "#666667" },
  # "sand" => 
  # "swamp-dry" => 
  # "swamp-wet" => 
  "cadastre" => { "color" => "#888889" },
  "act-cadastre" => { "color" => "#888889" },
  "watercourses" => { "color" => "#3860FF" },
  "water-areas" => { "color" => "#3860FF" },
  "dams" => { "color" => "#3860FF" },
  "pathways" => { "color" => "#000001" },
  "vehicular-tracks" => { "color" => "Dark Orange" },
  "roads-unsealed" => { "color" => "Dark Orange" },
  "roads-sealed" => { "color" => "Red" },
  "railways" => { "color" => "#000001" },
  "runways" => { "color" => "#000001" },
  "gates-grids" => { "color" => "#000001" },
  "dam-walls" => { "color" => "#000001" },
  "buildings" => { "color" => "#000001" },
  "transmission-lines" => { "color" => "#000001" },
  "towers" => { "color" => "#000001" },
  "labels-buildings" => { "color" => "#000001" },
  "labels-watercourses" => { "color" => "#000001" },
  "labels-water-areas" => { "color" => "#000001" },
  "labels-roads" => { "color" => "#000001" },
  "labels-contours-100m" => { "color" => "#000001" },
  "labels-fuzzy-extent" => { "color" => "#555556" },
  "control-circles" => { "color" => "Red" },
  "control-numbers" => { "color" => "Red" },
  "declination" => { "color" => "#000001" }
}.map do |filename, options|
  [ filename, File.join(output_dir, "#{filename}.tif"), options ]
end.select do |filename, path, options|
  File.exists? path
end.reject do |filename, path, options|
  %x[convert -quiet #{path} -format '%[max]' info:].to_i == 0
end.map do |filename, path, options|
  switches = { "set" => "label #{filename}", "type" => "TrueColorMatte" }
  if options["color"]
    switches["background"] = "'#{options["color"]}'"
    switches["alpha"] = "Shape"
  end
  switches = switches.map { |switch, value| "-#{switch} #{value}" }.join " "
  "#{path} #{switches}"
end

tif_path = File.join(output_dir, "#{map_name}.tif")
unless File.exist? tif_path
  puts "Compositing #{map_name}.tif ..."
  Tempfile.open([map_name, ".tif"]) do |file|
    sequence_string = sequences.map { |sequence| "\\( #{sequence} \\) -flatten" }.join " "
    %x[convert -quiet #{sequence_string} #{file.path}]
    %x[geotifcp -c packbits -e #{tfw_path} -4 '#{target_projection}' #{file.path} #{tif_path}]
  end
end

psd_path = File.join(output_dir, "#{map_name}.psd")
unless File.exist? psd_path
  puts "Building #{map_name}.psd ..."
  sequence_string = sequences.map { |sequence| "\\( #{sequence} \\)" }.join " "
  %x[convert -quiet #{tif_path} #{sequence_string} #{psd_path}]
end

# TODO: colour relief settings
# TODO: bring back post-actions
# TODO: in TiledMapService, reduce zoom level if too many tiles (as set in config)
# TODO: quote all file paths to allow spaces in dir names
# TODO: have all default configs in a single hash, use deep-merge
# TODO: fix Nokia dropped tiles?
# TODO: various label spacings ("interval" attribute)
# TODO: line styles, etc.
# TODO: label styles (italics, stretched, etc.) c.f. paper maps
# TODO: use ranges for bounds? use a Bounds class?
# TODO: don't abort on ArcIMS server error, just get next layer
# TODO: use raster fills for swamps, etc.?
# TODO: split water-areas by perenniality?
# TODO: have tiff compression (lzw,packbits,zip) be set by config option
# TODO: add multi-layer tiff output for use with GIMP?
# TODO: add compression to PSD?

# TODO: try ArcGIS explorer??

# swamp: ESRI IGL Font20, character 87?
# swamp: ESRI Caves 1, 195, 196, 197
# pine: ESRI Geometric Symbols, 221
# pine: ESRI Environmental & Icons, 50
# pine: ESRI US Forestry 2
# pine: ESRI US MUTCD 3, 241
# pine: ESRI Enviro Hazard Analysis, 111



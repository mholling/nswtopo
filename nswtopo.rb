#!/usr/bin/env ruby

require 'uri'
require 'net/http'
require 'rexml/document'
require 'tmpdir'
require 'yaml'
require 'fileutils'

EARTH_RADIUS = 6378137.0

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
      result.merge(key => result[key].is_a?(Hash) ? result[key].deep_merge(value) : value)
    end
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
end

InternetError = Class.new(Exception)
BadLayer = Class.new(Exception)

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

def bounds_intersect?(bounds1, bounds2)
  [ bounds1, bounds2 ].transpose.map do |bound1, bound2|
    bound1.max > bound2.min && bound1.min < bound2.max
  end.inject(:&)
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
  
  def dataset(input_bounds, input_projection, scaling, options_or_array, dir)
    projected_bounds = transform_bounds(input_projection, params["envelope"]["projection"], input_bounds)
    return nil unless bounds_intersect?(projected_bounds, params["envelope"]["bounds"])
    
    options_array = [ options_or_array ].flatten
    
    margin = options_array.any? { |options| options["text"] } ? 0 : (1.27 * scaling.ppi / 25.4).ceil
    cropped_tile_sizes = params["tile_sizes"].map { |tile_size| tile_size - 2 * margin }
    
    scales = options_array.map { |options| options["scale"] }.compact.uniq
    abort("more than one scale specified") if scales.length > 1
    dpi = scales.any? ? (scales.first * scaling.ppi).round : params["dpi"]
    
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
        sleep params["interval"] if params["interval"]
        xml = REXML::Document.new(post_response.body)
        error = xml.elements["/ARCXML/RESPONSE/ERROR"]
        raise InternetError.new(error.text) if error
        get_uri = URI.parse xml.elements["/ARCXML/RESPONSE/IMAGE/OUTPUT"].attributes["url"]
        get_uri.host = params["host"] if params["keep_host"]
        http_get(get_uri, "retries" => 5) do |get_response|
          File.open(tile_path, "w") { |file| file << get_response.body }
        end
      end
      
      %x[mogrify -crop #{cropped_extents.join "x"}+#{margin}+#{margin} '#{tile_path}']
      [ cropped_bounds, scaling.metres_per_pixel, tile_path ]
    end
  end
end

class TiledMapService < Service
  def dataset(input_bounds, input_projection, scaling, options, dir)
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
    
    puts "  downloading #{counts.inject(:*)} tiles at zoom level #{zoom}..."
    
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
      
      longitude, latitude = transform_coordinates(projection, "EPSG:4326", centre)
      
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
          File.open(tile_path, "w") { |file| file << response.body }
          %x[mogrify -quiet -type TrueColorMatte -depth 8 -format png -define png:color-type=2 '#{tile_path}']
          %x[mogrify -quiet -crop #{cropped_tile_sizes.join "x"}+#{crops.first.first}+#{crops.last.last} '#{tile_path}']
        end
        non_blank_fraction = %x[convert '#{tile_path}' -fill white +opaque black -format "%[fx:mean]" info:].to_f
        break if non_blank_fraction > 0.95
      end
      
      [ bounds, metres_per_pixel, tile_path ]
    end
  end
end

class LPIOrthoService < Service
  def dataset(input_bounds, input_projection, scaling, options, dir)
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
    return nil if images_attributes.empty?
    
    tile_size = params["tile_size"]
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
        query = "?image?type=png&transparent=true&l=#{zoom}&tx=#{tx}&ty=#{ty}&ts=#{tile_size}&layers=#{image}"
        query += "&inregion=#{attributes['region'].flatten.join(',')},INSRC" if attributes['region']
        [ query, tile_bounds, resolutions ]
      end
    end.inject(:+).with_progress.with_index.map do |(query, tile_bounds, resolutions), index|
      uri = URI::HTTP.build :host => params["host"], :path => "/ImageX/ImageX.dll", :query => query
      tile_path = File.join(dir, "tile.#{index}.png")
      http_get(uri, "retries" => 5) do |response|
        File.open(tile_path, "w") { |file| file << response.body }
      end
      sleep params["interval"]
      [ tile_bounds, resolutions.first, tile_path ]
    end
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
      }.map { |key, value| "#{key}=#{value}" }.join("&")
      uri = URI::HTTP.build :host => "onearth.jpl.nasa.gov", :path => "/wms.cgi", :query => URI.escape(query)

      http_get(uri, "retries" => 5) do |response|
        File.open(tile_path, "w") { |file| file << response.body }
        write_world_file([ tile_bounds.first.min, tile_bounds.last.max ], units_per_pixel, "#{tile_path}w")
        sleep params["interval"]
      end
      "'#{tile_path}'"
    end
    
    vrt_path = File.join(dir, "dem.vrt")
    relief_path = File.join(dir, "output.tif")
    output_path = File.join(dir, "output.png")
    %x[gdalbuildvrt '#{vrt_path}' #{tile_paths.join " "}]
    
    case options["name"]
    when "shaded-relief"
      altitude = params["altitude"]
      azimuth = options["azimuth"]
      exaggeration = params["exaggeration"]
      %x[gdaldem hillshade -s 111120 -alt #{altitude} -z #{exaggeration} -az #{azimuth} '#{vrt_path}' '#{relief_path}' -q]
    when "color-relief"
      colours = { "0%" => "black", "100%" => "white" }
      colour_path = File.join(dir, "colours.txt")
      File.open(colour_path, "w") do |file|
        colours.each { |elevation, colour| file.puts "#{elevation} #{colour}" }
      end
      %x[gdaldem color-relief '#{vrt_path}' '#{colour_path}' '#{relief_path}' -q]
    end
    %x[convert '#{relief_path}' -quiet -type TrueColorMatte -depth 8 -format png -define png:color-type=2 '#{output_path}']
    
    [ [ bounds, units_per_pixel, output_path ] ]
  end
end

class AnnotationService < Service
  def dataset(input_bounds, input_projection, scaling, options, dir)
    []
  end
  
  # TODO: this is wrong if the projection is not a UTM grid!
  def post_process(path, bounds, scaling, options, dir)
    extents = bounds.map { |bound| bound.max - bound.min }
    draw_string = draw(bounds, extents, scaling, options)
    %x[mogrify -quiet -units PixelsPerInch -density #{scaling.ppi} #{draw_string} '#{path}']
  end
end

class GridService < AnnotationService
  def draw(bounds, extents, scaling, options)
    intervals = params["intervals"]
    fontsize = params["fontsize"]
    
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
      "-fill black -draw 'color 0,0 reset' -stroke white -strokewidth 1 #{string}"
    when "eastings"
      centre_pixel = tick_pixels.last[centre_indices.last]
      dx, dy = [ 0.04 * scaling.ppi ] * 2
      string = [ tick_pixels, tick_coords ].transpose.first.transpose.map { |pixel, tick| "-draw \"translate #{pixel-dx},#{centre_pixel-dy} rotate -90 text 0,0 '#{tick}'\"" }.join " "
      "-fill black -draw 'color 0,0 reset' -fill white -pointsize #{fontsize} -family 'Arial Narrow' -weight 100 #{string}"
    when "northings"
      centre_pixel = tick_pixels.first[centre_indices.first]
      dx, dy = [ 0.04 * scaling.ppi ] * 2
      string = [ tick_pixels, tick_coords ].transpose.last.transpose.map { |pixel, tick| "-draw \"text #{centre_pixel+dx},#{pixel-dy} '#{tick}'\"" }.join " "
      "-fill black -draw 'color 0,0 reset' -fill white -pointsize #{fontsize} -family 'Arial Narrow' -weight 100 #{string}"
    end
  end
end

class DeclinationService < AnnotationService
  def get_declination(coords)
    wgs84_coords = transform_coordinates(projection, "EPSG:4326", coords)
    degrees_minutes_seconds = wgs84_coords.map do |coord|
      [ (coord > 0 ? 1 : -1) * coord.abs.floor, (coord.abs * 60).floor % 60, (coord.abs * 3600).round % 60 ]
    end
    today = Date.today
    year_month_day = [ today.year, today.month, today.day ]
    url = "http://www.ga.gov.au/bin/geoAGRF?latd=%i&latm=%i&lats=%i&lond=%i&lonm=%i&lons=%i&elev=0&year=%i&month=%i&day=%i&Ein=D" % (degrees_minutes_seconds.reverse.flatten + year_month_day)
    http_get(URI.parse url) do |response|
      /D\s*=\s*(\d+\.\d+)/.match(response.body) { |match| match.captures[0].to_f }
    end
  end
  
  def draw(bounds, extents, scaling, options)
    spacing = params["spacing"]
    angle = params["angle"] || get_declination(bounds.map { |bound| 0.5 * bound.inject(:+) })
    
    if angle
      radians = angle * Math::PI / 180.0
      x_spacing = spacing / Math::cos(radians) / scaling.metres_per_pixel
      dx = extents.last * Math::tan(radians)
      x_min = [ 0, dx ].min
      x_max = [ extents.first, extents.first + dx ].max
      line_count = (x_max - x_min) / x_spacing
      x_starts = (1..line_count).map { |n| x_min + n * x_spacing }
      string = x_starts.map { |x| "-draw 'line #{x.to_i},0 #{(x - dx).to_i},#{extents.last}'" }.join " "
      "-fill black -draw 'color 0,0 reset' -stroke white -strokewidth 1 #{string}"
    end
  end
end

class ControlService < AnnotationService
  def dataset(*args)
    File.exists?(params["path"]) ? super(args) : nil
  end
  
  def draw(bounds, extents, scaling, options)
    xml = REXML::Document.new(File.open params["path"])
    
    waypoints, numbers = case
    when xml.elements["/gpx"]
      xml.elements.collect("/gpx//wpt") do |element|
        [ [ element.attributes["lon"].to_f, element.attributes["lat"].to_f ], element.elements["name"].text ]
      end.transpose
    when xml.elements["/kml"]
      xml.elements.collect("/kml//Placemark") do |element|
        [ element.elements["Point/coordinates"].text.split(',')[0..1].map { |coord| coord.to_f }, element.elements["name"].text ]
      end.transpose
    else
      raise BadLayer.new("#{params["path"]} not a valid GPX or KML file")
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
      "-fill black -draw 'color 0,0 reset' -stroke white -strokewidth #{strokewidth} #{string}"
    when "numbers"
      "-fill black -draw 'color 0,0 reset' -fill white -pointsize #{params['fontsize']} -family 'Arial' -weight Normal #{string}"
    end
  rescue REXML::ParseException
    raise BadLayer.new("#{params["path"]} not a valid GPX or KML file")
  end
end

output_dir = Dir.pwd
config = YAML.load(
%q[
name: map
scale: 25000
ppi: 300
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
  fontsize: 4.5
relief:
  altitude: 45
  azimuth:
    - 315
    - 45
  exaggeration: 1
controls:
  fontsize: 14
  diameter: 7.0
  thickness: 0.2
formats:
  - tif
  - layered.tif
exclude:
  - utm-grid
  - utm-eastings
  - utm-northings
  - aerial-nokia
colours:
  pine: '#009f00'
  orchards-plantations: '#009f00'
  built-up-areas: '#F8FF73'
  contours: 'Dark Magenta'
  swamp-wet: '#00d3ff'
  swamp-dry: '#e3bf9a'
  watercourses: '#0033ff'
  ocean: '#7b96ff'
  dams: '#0033ff'
  water-areas-perennial: '#7b96ff'
  water-areas-intermittent: '#7b96ff'
  water-areas-dry: '#7b96ff'
  water-area-boundaries: '#0033ff'
  reef: 'Cyan'
  sand: '#ff6600'
  intertidal: '#1b2e7b'
  inundation: '#00d3ff'
  cliffs: '#ddddde'
  clifftops: '#ff00ba'
  rocks-pinnacles: '#ff00ba'
  buildings: '#222223'
  building-areas: '#666667'
  cadastre: '#888889'
  act-cadastre: '#888889'
  excavation: '#333334'
  coastline: '#000001'
  dam-walls: '#000001'
  wharves: '#000001'
  pathways: '#000001'
  tracks-4wd: 'Dark Orange'
  tracks-vehicular: 'Dark Orange'
  roads-unsealed: 'Dark Orange'
  roads-sealed: 'Red'
  gates-grids: '#000001'
  railways: '#000001'
  landing-grounds: '#333334'
  transmission-lines: '#000001'
  caves: '#000001'
  towers: '#000001'
  windmills: '#000001'
  lighthouses: '#000001'
  mines: '#000001'
  yards: '#000001'
  trig-points: '#000001'
  labels: '#000001'
  control-circles: 'Red'
  control-numbers: 'Red'
  declination: '#000001'
  utm-grid: '#000001'
  utm-eastings: '#000001'
  utm-northings: '#000001'
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
]
).deep_merge YAML.load(File.open(File.join(output_dir, "config.yml")))

map_name = config["name"]
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
puts "  1:%i scale" % scaling.scale
puts "  %.1fcm x %.1fcm @ %i ppi" % [ *target_extents.map { |extent| extent * 2.54 / scaling.ppi }, scaling.ppi ]
puts "  %.1f megapixels (%i x %i)" % [ 0.000001 * target_extents.inject(:*), *target_extents ]

lpi_ortho = LPIOrthoService.new(
  "host" => "lite.maps.nsw.gov.au",
  "tile_size" => 1024,
  "interval" => 1.0,
  "projection" => "EPSG:3308"
)
nokia_maps = TiledMapService.new(
  "uri" => "http://m.ovi.me/?c=${latitude},${longitude}&t=${name}&z=${zoom}&h=${vsize}&w=${hsize}&f=${format}&nord&nodot",
  "projection" => "EPSG:3857",
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 1.2,
  "crops" => [ [ 0, 0 ], [ 26, 0 ] ],
  "tile_limit" => 250,
  "retries_on_blank" => 1
)
google_maps = TiledMapService.new(
  "uri" => "http://maps.googleapis.com/maps/api/staticmap?zoom=${zoom}&size=${hsize}x${vsize}&scale=1&format=${format}&maptype=${name}&sensor=false&center=${latitude},${longitude}",
  "projection" => "EPSG:3857",
  "tile_sizes" => [ 640, 640 ],
  "interval" => 1.2,
  "crops" => [ [ 0, 0 ], [ 30, 0 ] ],
  "tile_limit" => 250
)
topo_portlet = ArcIMS.new(
  "host" => "gsp.maps.nsw.gov.au",
  "path" => "/servlet/com.esri.esrimap.Esrimap",
  "name" => "topo_portlet",
  "keep_host" => true,
  "projection" => target_projection,
  "wkt" => target_wkt,
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
  "projection" => target_projection,
  "wkt" => target_wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "dpi" => 74,
  "envelope" => {
    "bounds" => [ [ 140.05983881892, 154.575951211079 ], [ -37.740334035, -27.924909045 ] ],
    "projection" => "EPSG:4283"
  })
crown_portlet = ArcIMS.new(
  "host" => "gsp.maps.nsw.gov.au",
  "path" => "/servlet/com.esri.esrimap.Esrimap",
  "name" => "crown_portlet",
  "keep_host" => true,
  "projection" => target_projection,
  "wkt" => target_wkt,
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
  "projection" => target_projection,
  "wkt" => target_wkt,
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
  "projection" => target_projection,
  "wkt" => target_wkt,
  "tile_sizes" => [ 1024, 1024 ],
  "interval" => 0.1,
  "dpi" => 96,
  "envelope" => {
    "bounds" => [ [ 659890.105040274, 720782.12808229 ], [ 6022931.0546655, 6111100.93973127 ] ],
    "projection" => "EPSG:32755"
  })
grid_service = GridService.new({ "projection" => nearest_utm }.merge config["grid"])
oneearth_relief = OneEarthDEMRelief.new({ "interval" => 0.3 }.merge config["relief"])
declination_service = DeclinationService.new({ "projection" => target_projection }.merge config["declination"])
control_service = ControlService.new({
  "path" => config["controls"]["path"] || File.join(output_dir, config["controls"]["file"] || "controls.gpx"),
  "projection" => target_projection,
}.merge config["controls"])

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
        "text" => { config["contours"]["source"] => { "fontsize" => 3.4 } }
      },
      { # watercourse labels
        "from" => "HydroLine_Label_1",
        "where" => "ClassSubtype = 1",
        "label" => { "field" => "delivsdm:geodb.HydroLine.HydroName delivsdm:geodb.HydroLine.HydroNameType", "linelabelposition" => "placeabove" },
        "lookup" => "delivsdm:geodb.HydroLine.relevance",
        "text" => {
          1 => { "fontsize" => 10.9, "printmode" => "allcaps", "fontstyle" => "italic" },
          2 => { "fontsize" => 10.1, "printmode" => "allcaps", "fontstyle" => "italic" },
          3 => { "fontsize" => 9.3, "printmode" => "allcaps", "fontstyle" => "italic" },
          4 => { "fontsize" => 8.5, "printmode" => "allcaps", "fontstyle" => "italic" },
          5 => { "fontsize" => 7.7, "printmode" => "titlecaps", "fontstyle" => "italic" },
          6 => { "fontsize" => 6.9, "printmode" => "titlecaps", "fontstyle" => "italic" },
          7 => { "fontsize" => 6.1, "printmode" => "titlecaps", "fontstyle" => "italic" },
          8 => { "fontsize" => 5.3, "printmode" => "titlecaps", "fontstyle" => "italic" },
          9 => { "fontsize" => 4.5, "printmode" => "titlecaps", "fontstyle" => "italic" },
          10 => { "fontsize" => 3.7, "printmode" => "titlecaps", "fontstyle" => "italic" }
        }
      },
      { # waterbody labels
        "from" => "HydroArea_Label_1",
        "label" => { "field" => "delivsdm:geodb.HydroArea.HydroName delivsdm:geodb.HydroArea.HydroNameType" },
        "lookup" => "delivsdm:geodb.HydroArea.classsubtype",
        "text" => { 1 => { "fontsize" => 5.5, "printmode" => "titlecase" } }
      },
      { # fuzzy water labels
        "from" => "FuzzyExtentWaterArea_1",
        "label" => { "field" => "delivsdm:geodb.FuzzyExtentWaterArea.HydroName delivsdm:geodb.FuzzyExtentWaterArea.HydroNameType" },
        "lookup" => "delivsdm:geodb.FuzzyExtentWaterArea.classsubtype",
        "text" => { 2 => { "fontsize" => 4.2, "fontstyle" => "italic", "printmode" => "titlecaps" } }
      },
      { # road labels
        "from" => "RoadSegment_Label_1",
        "lookup" => "delivsdm:geodb.RoadSegment.FunctionHierarchy",
        "label" => { "field" => "delivsdm:geodb.RoadSegment.RoadNameBase delivsdm:geodb.RoadSegment.RoadNameType delivsdm:geodb.RoadSegment.RoadNameSuffix" },
        "text" => {
          "1;2;3;4;5" => { "fontsize" => 4.5, "fontstyle" => "italic", "printmode" => "allupper" },
          "6;7;8" => { "fontsize" => 3.4, "fontstyle" => "italic", "printmode" => "allupper" },
        }
      },
      { # fuzzy area labels
        "from" => "FuzzyExtentArea_Label_1",
        "label" => { "field" => "delivsdm:geodb.FuzzyExtentArea.GeneralName" },
        "text" => { "fontsize" => 5.5, "printmode" => "allcaps" }
      },
      { # fuzzy line labels
        "from" => "FuzzyExtentLine_Label_1",
        "label" => { "field" => "delivsdm:geodb.FuzzyExtentLine.GeneralName" },
        "text" => { "fontsize" => 5.5, "printmode" => "allcaps" }
      },
      { # building labels
        "from" => "BuildingComplexPoint_Label_1",
        "label" => { "field" => "delivsdm:geodb.BuildingComplexPoint.GeneralName" },
        "text" => { "fontsize" => 3, "fontstyle" => "italic", "printmode" => "titlecaps", "interval" => 2.0 }
      },
      { # cave labels
        "from" => "DLSPoint_Label_1",
        "lookup" => "delivsdm:geodb.DLSPoint.ClassSubtype",
        "label" => { "field" => "delivsdm:geodb.DLSPoint.GeneralName" },
        "text" => { 1 => { "fontsize" => 3, "printmode" => "titlecaps", "interval" => 2.0 } }
      },
    ],
    "contours" => [
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, #{config["contours"]["interval"]}) = 0 AND sourceprogram = #{config["contours"]["source"]}",
        "lookup" => "delivsdm:geodb.Contour.ClassSubtype",
        "line" => {
          1 => { "width" => 1 },
          3 => { "width" => 1, "type" => "dash" }
        },
        "hashline" => {
          2 => { "width" => 2, "linethickness" => 1, "thickness" => 1, "interval" => 8 }
        }
      },
      {
        "from" => "Contour_1",
        "where" => "MOD(elevation, #{config["contours"]["index"]}) = 0 AND elevation > 0 AND sourceprogram = #{config["contours"]["source"]}",
        "lookup" => "delivsdm:geodb.Contour.ClassSubtype",
        "line" => {
          1 => { "width" => 2 },
        },
        "hashline" => {
          2 => { "width" => 3, "linethickness" => 2, "thickness" => 1, "interval" => 8 }
        }
      },
    ],
    "watercourses" => {
      "from" => "HydroLine_1",
      "where" => "ClassSubtype = 1",
      "lookup" => "delivsdm:geodb.HydroLine.Perenniality",
      "line" => {
        1 => { "width" => 2, "antialiasing" => false },
        2 => { "width" => 1 },
        3 => { "width" => 1, "type" => "dash" }
      }
    },
    "water-areas-perennial" => {
      "from" => "HydroArea_1",
      "lookup" => "delivsdm:geodb.HydroArea.perenniality",
      "polygon" => { 1 => { "boundary" => false } }
    },
    "water-areas-intermittent" => {
      "from" => "HydroArea_1",
      "lookup" => "delivsdm:geodb.HydroArea.perenniality",
      "polygon" => { 2 => { "boundary" => false } }
    },
    "water-areas-dry" => {
      "from" => "HydroArea_1",
      "lookup" => "delivsdm:geodb.HydroArea.perenniality",
      "polygon" => { 3 => { "boundary" => false } }
    },
    "water-area-boundaries" => {
      "from" => "HydroArea_1",
      "line" => { "width" => 1 }
    },
    "dams" => {
      "from" => "HydroPoint_1",
      "lookup" => "delivsdm:geodb.HydroPoint.ClassSubtype",
      "marker" => { 1 => { "type" => "square", "width" => 0.8 } }
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
        "1;2;3" => { "width" => 7 },
        "4;5"   => { "width" => 5 },
        "6"     => { "width" => 3 },
        "7"     => { "width" => 2 }
      }
    },
    "roads-unsealed" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "where" => "Surface = 2",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => {
        "1;2;3" => { "width" => 7 },
        "4;5"   => { "width" => 5 },
        "6"     => { "width" => 3 },
        "7"     => { "width" => 2 }
      }
    },
    "tracks-vehicular" => {
      "scale" => 0.6,
      "from" => "RoadSegment_1",
      "where" => "Surface = 2",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => { 8 => { "width" => 2, "type" => "dash" } },
    },
    "tracks-4wd" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "where" => "Surface = 3 OR Surface = 4",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => { 8 => { "width" => 2, "type" => "dash" } },
    },
    "pathways" => {
      "scale" => 0.4,
      "from" => "RoadSegment_1",
      "lookup" => "delivsdm:geodb.RoadSegment.functionhierarchy",
      "line" => { 9 => { "width" => 2, "type" => "dash" } },
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
      "line" => { 3 => { "width" => 1, "type" => "dot", "antialiasing" => false } }
    },
    "caves" => {
      "from" => "DLSPoint_1",
      "lookup" => "delivsdm:geodb.DLSPoint.ClassSubtype",
      "truetypemarker" => { 1 => { "font" => "ESRI Default Marker", "fontsize" => 7, "character" => 216 } }
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
    "misc-perimeters" => {
      "from" => "GeneralCulturalLine_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalLine.classsubtype",
      "line" => { 3 => { "width" => 1 } },
    },
    "towers" => {
      "from" => "GeneralCulturalPoint_1",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.ClassSubtype",
      "truetypemarker" => { 7 => { "font" => "ESRI Cartography", "character" => 100, "fontsize" => 7 } }
    },
    "mines" => {
      "from" => "GeneralCulturalPoint_1",
      "where" => "generalculturaltype = 11 OR generalculturaltype = 12",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.ClassSubtype",
      "truetypemarker" => { 4 => { "font" => "ESRI Cartography", "character" => 204, "fontsize" => 7 } }
    },
    "yards" => {
      "from" => "GeneralCulturalPoint_1",
      "where" => "ClassSubtype = 4",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.generalculturaltype",
      "marker" => { "6;9" => { "type" => "square", "width" => 0.8, "color" => "0,0,0", "outline" => "255,255,255" } }
    },
    "windmills" => {
      "from" => "GeneralCulturalPoint_1",
      "where" => "generalculturaltype = 8",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.ClassSubtype",
      "truetypemarker" => { 4 => { "font" => "ESRI Cartography", "character" => 228, "fontsize" => 5.5 } }
    },
    "lighthouses" => {
      "from" => "GeneralCulturalPoint_1",
      "where" => "generalculturaltype = 1",
      "lookup" => "delivsdm:geodb.GeneralCulturalPoint.ClassSubtype",
      "truetypemarker" => { 12 => { "font" => "ESRI Cartography", "character" => 227, "fontsize" => 7 } }
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
        1 => { "width" => 3 },
        2 => { "width" => 6 },
        3 => { "width" => 0.5 }
      }
    },
    "gates-grids" => {
      "from" => "TrafficControlDevice_1",
      "lookup" => "delivsdm:geodb.TrafficControlDevice.ClassSubtype",
      "truetypemarker" => {
        1 => { "font" => "ESRI Geometric Symbols", "fontsize" => 3, "character" => 178 }, # gate
        2 => { "font" => "ESRI Geometric Symbols", "fontsize" => 3, "character" => 177 }  # grid
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
    "nsw-border" => {
      "scale" => 0.5,
      "from" => "Border_1",
      "line" => { "width" => 2, "type" => "dash_dot_dot" }
    },
    "trig-points" => {
      "from" => "SurveyMarks_1",
      "lookup" => "delivsdm:geodb.SurveyMark.ClassSubtype",
      "truetypemarker" => { 1 => { "font" => "ESRI Geometric Symbols", "fontsize" => 6, "character" => 180 } }
    },
    "town-labels" => {
      "from" => "Town_Label_1",
      "label" => { "field" => "name" },
      "text" => { "fontsize" => 11 }
    }
  },
  crown_portlet => {
    "crown-reserves" => {
      "from" => "CrownReserve_Lot_1",
      "lookup" => "delivsdm:geodb.crownaccountpolygon.crownlandsubtype",
      "polygon" => { 1 => { } }
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
  grid_service => {
    "utm-grid" => { "name" => "grid" },
    "utm-eastings" => { "name" => "eastings" },
    "utm-northings" => { "name" => "northings" }
  },
  declination_service => {
    "declination" => { }
  },
  control_service => {
    "control-numbers" => { "name" => "numbers" },
    "control-circles" => { "name" => "circles" }
  },
  lpi_ortho => {
    "aerial-lpi-ads40" => { "config" => "/ADS40ImagesConfig.js" },
    "aerial-lpi-sydney" => { "config" => "/SydneyImagesConfig.js" },
    "aerial-lpi-regional" => { "config" => "/NSWRegionalCentresConfig.js" },
    "aerial-lpi-eastcoast" => { "image" => "/Imagery/lr94ortho1m.ecw" }
  },
  google_maps => {
    "aerial-google" => {
      "name" => "satellite",
      "format" => "jpg"
    }
  },
  nokia_maps => {
    "aerial-nokia" => {
      "name" => 1,
      "format" => 1
    }
  },
  oneearth_relief => config["relief"]["azimuth"].map do |azimuth|
    { "shaded-relief-#{azimuth}" => { "name" => "shaded-relief", "azimuth" => azimuth } }
  end.inject(:merge).merge(
    "elevation" => { "name" => "color-relief" }
  ),
}

services.each do |service, layers|
  layers.each do |label, options|
    begin
      output_path = File.join(output_dir, "#{label}.tif")
      unless File.exists?(output_path)
        puts "Layer: #{label}"
        Dir.mktmpdir do |temp_dir|
          dataset = service.dataset(target_bounds, target_projection, scaling, options, temp_dir)
          if dataset
            working_path = File.join(temp_dir, "layer.tif")
            canvas_path = File.join(temp_dir, "canvas.tif")
            
            puts "  assembling..."
            %x[convert -size #{target_extents.join 'x'} -units PixelsPerInch -density #{scaling.ppi} canvas:transparent -type TrueColorMatte -depth 8 '#{canvas_path}']
            %x[geotifcp -c lzw -e '#{tfw_path}' -4 '#{target_projection}' '#{canvas_path}' '#{working_path}']
            
            unless dataset.empty?
              dataset_paths = dataset.collect do |bounds, resolution, path|
                topleft = [ bounds.first.min, bounds.last.max ]
                write_world_file(topleft, resolution, "#{path}w")
                %x[mogrify -quiet -type TrueColorMatte -depth 8 -format png -define png:color-type=2 '#{path}']
                "'#{path}'"
              end
              
              vrt_path = File.join(temp_dir, "#{label}.vrt")
              %x[gdalbuildvrt '#{vrt_path}' #{dataset_paths.join " "}]
              %x[gdalwarp -s_srs "#{service.projection}" -dstalpha -r bilinear '#{vrt_path}' '#{working_path}']
            end
          
            if service.respond_to? :post_process
              puts "  processing..."
              service.post_process(working_path, target_bounds, scaling, options, temp_dir)
            end
        
            %x[convert -quiet '#{working_path}' -compress LZW '#{output_path}']
          else
            puts "  (no data)"
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
  { format => File.join(output_dir, "#{map_name}.#{format}") }
end.inject(:merge).reject do |format, path|
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
    
    %x[convert -size 480x480 -virtual-pixel tile canvas: -fx 'j%12==0' \\( +clone +noise Random -blur 0x2 -threshold 50% \\) -compose Multiply -composite '#{inundation_tile_path}']
    %x[convert -size 480x480 -virtual-pixel tile canvas: -fx 'j%12==7' \\( +clone +noise Random -threshold 88% \\) -compose Multiply -composite -morphology Dilate '11: #{swamp}' '#{inundation_tile_path}' -compose Plus -composite '#{swamp_wet_tile_path}']
    %x[convert -size 480x480 -virtual-pixel tile canvas: -fx 'j%12==7' \\( +clone +noise Random -threshold 88% \\) -compose Multiply -composite -morphology Dilate '11: #{swamp}' '#{inundation_tile_path}' -compose Plus -composite '#{swamp_dry_tile_path}']
    %x[convert -size 400x400 -virtual-pixel tile canvas: +noise Random -blur 0x2 -modulate 100,1,100 -auto-level -ordered-dither threshold,3 +level 60%,80% '#{rock_area_tile_path}']
    
    config["patterns"].each do |label, string|
      if File.exists?(string)
        tile_path = string
      elsif File.exists?(File.join(output_dir, string))
        tile_path = File.join(output_dir, string)
      else
        tile_path = File.join(temp_dir, "tile-#{label}.tif")
        tile = string.split(" ").map { |line| line.split(line =~ /,/ ? "," : "").map { |number| number.to_f } }
        abort("Error: fill pattern for '#{label}' must be rectangular") unless tile.map { |line| line.length }.uniq.length == 1
        maximum = tile.flatten.max
        tile.map! { |row| row.map { |number| number / maximum } }
        size = "#{tile.first.length}x#{tile.length}"
        kernel = "#{size}: #{tile.map { |row| row.join "," }.join " "}"
        %x[convert -size #{size} -virtual-pixel tile canvas: -fx '(i==0)&&(j==0)' -morphology Convolve '#{kernel}' '#{tile_path}']
      end
    end
    
    puts "  preparing layers..."
    layers = [
      "aerial-google",
      "aerial-nokia",
      "aerial-lpi-ads40",
      "aerial-lpi-eastcoast",
      "aerial-lpi-regional",
      "vegetation",
      "pine",
      "orchards-plantations",
      "built-up-areas",
      "rock-area",
      "contours",
      "swamp-wet",
      "swamp-dry",
      "sand",
      "inundation",
      "cadastre",
      "act-cadastre",
      "watercourses",
      "ocean",
      "dams",
      "water-areas-perennial",
      "water-areas-intermittent",
      "water-areas-dry",
      "water-area-boundaries",
      "reef",
      "intertidal",
      "cliffs",
      "clifftops",
      "rocks-pinnacles",
      "excavation",
      "coastline",
      "dam-walls",
      "wharves",
      "pathways",
      "tracks-4wd",
      "tracks-vehicular",
      "roads-unsealed",
      "roads-sealed",
      "gates-grids",
      "railways",
      "landing-grounds",
      "transmission-lines",
      "buildings",
      "building-areas",
      "caves",
      "towers",
      "windmills",
      "lighthouses",
      "mines",
      "yards",
      "trig-points",
      "labels",
      "control-circles",
      "control-numbers",
      "declination",
      "utm-grid",
      "utm-eastings",
      "utm-northings"
    ].reject do |label|
      config["exclude"].include? label
    end.map do |label|
      [ label, File.join(output_dir, "#{label}.tif") ]
    end.select do |label, path|
      File.exists? path
    end.reject do |label, path|
      %x[convert -quiet '#{path}' -format '%[max]' info:].to_i == 0
    end.with_progress.map do |label, path|
      layer_path = File.join(temp_dir, "#{label}.tif")
      tile_path = File.join(temp_dir, "tile-#{label}.tif")
      colour = config["colours"][label]
      sequence = case
      when File.exist?(tile_path)
        if colour
          "-alpha Copy \\( +clone -tile '#{tile_path}' -draw 'color 0,0 reset' -background '#{colour}' -alpha Shape \\) -compose In -composite"
        else
          "-alpha Copy \\( +clone -tile '#{tile_path}' -draw 'color 0,0 reset' \\) -compose In -composite"
        end
      when colour
        "-background '#{colour}' -alpha Shape"
      else
        ""
      end
      %x[convert '#{path}' #{sequence} -type TrueColorMatte -depth 8 '#{layer_path}']
      [ label, layer_path ]
    end
    
    flattened, layered = [ " -flatten", "" ].map do |compose|
      layers.map do |label, layer_path|
        "\\( '#{layer_path}' -set label #{label} \\)#{compose}"
      end.join " "
    end
    
    formats_paths.each do |format, path|
      temp_path = File.join(temp_dir, "composite.#{format}")
      puts "  compositing #{map_name}.#{format}"
      sequence = case format.downcase
      when "psd" then "#{flattened} #{layered}"
      when /layer/ then layered
      else flattened
      end
      %x[convert -quiet #{sequence} '#{temp_path}']
      if format.downcase =~ /tif/
        %x[geotifcp -e '#{tfw_path}' -4 '#{target_projection}' '#{temp_path}' '#{path}']
      else
        FileUtils.mv(temp_path, path)
      end
    end
  end
end


# TODO: various label spacings ("interval" attribute)

# TODO: solve water-area-boundaries problem (e.g. for test-eden)
# TODO: have water boundaries only on perennial water bodies? (solves dam overlap problem)
# TODO: merge water areas?
# TODO: differentiate intermittent and perennial water areas?
# TODO: use dot pattern for water-areas-dry instead?

# TODO: add trig-point labels?
# TODO: town labels font-size? make it a value map according to population?
# TODO: better vegetation labels?

# TODO: access missing content (FuzzyExtentPoint, SpotHeight, AncillaryHydroPoint, PointOfInterest, RelativeHeight, ClassifiedFireTrail, PlacePoint, PlaceArea) via workspace name?
# TODO: include point layers as invisible layers in label layer to avoid overlap?
# TODO: specify resampling algorithm on a layer-by-layer basis?
# TODO: sort out file format issue for LPI ortho service
# TODO: add LPI orthographic images to composite stack
# TODO: legends?
# TODO: have imagemagick and gdal paths be configurable
# TODO: remove transparency channel before final save (or have transparency be a layer option)


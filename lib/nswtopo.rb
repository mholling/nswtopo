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
require 'rbconfig'
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

require_relative 'helpers'
require_relative 'avl_tree'
require_relative 'geometry'
require_relative 'nswtopo/helpers'
require_relative 'nswtopo/gis'
require_relative 'nswtopo/map'
# require_relative 'nswtopo/formats'
require_relative 'nswtopo/layer'

module NSWTopo
  PartialFailureError = Class.new RuntimeError
  FORMATS = %w[png tif gif jpg kmz mbtiles zip psd pdf prj]
  # TODO: extract from Formats module automatically?

  def self.init(archive, options, config)
    map = Map.init(archive, options)
    map.save
    puts map
  end

  def self.info(archive, options, config)
    puts Map.new(archive)
  end

  def self.add(archive, layer, options, config)
    create_options = {
      after: options.delete(:after)&.gsub(?/, ?.),
      before: options.delete(:before)&.gsub(?/, ?.),
      overwrite: options.delete(:overwrite)
    }
    map = Map.new(archive)
    Enumerator.new do |yielder|
      layers = [ layer ]
      while layers.any?
        layer, basedir = layers.shift
        path = Pathname(layer).expand_path(*basedir)
        case layer
        when /^controls\.(gpx|kml)$/i
          yielder << [ path.basename(path.extname).to_s, "type" => "Control", "path" => path ]
        when /\.(gpx|kml)$/i
          yielder << [ path.basename(path.extname).to_s, "type" => "Overlay", "path" => path ]
        when /\.(tiff?|png|jpg)$/i
          yielder << [ path.basename(path.extname).to_s, "type" => "Import", "path" => path ]
        when "Grid", "Declination"
          yielder << [ layer.downcase, "type" => layer ]
        when /\.yml$/i
          basedir ||= path.parent
          raise "couldn't find '#{layer}'" unless path.file?
          case contents = YAML.load(path.read)
          when Array
            contents.reverse.map do |item|
              Pathname(item.to_s)
            end.each do |relative_path|
              raise "#{relative_path} is not a relative path" unless relative_path.relative?
              layers.prepend [ Pathname(relative_path).expand_path(path.parent).relative_path_from(basedir).to_s, basedir ]
            end
          when Hash
            name = path.sub_ext("").relative_path_from(basedir).descend.map(&:basename).join(?.)
            yielder << [ name, contents.merge("source" => path) ]
          else
            raise "couldn't parse #{path}"
          end
        else
          path = Pathname("#{layer}.yml")
          raise "#{layer} is not a relative path" unless path.relative?
          basedir ||= [ Pathname.pwd, Pathname(__dir__).parent / "layers" ].find do |root|
            path.expand_path(root).file?
          end
          layers.prepend [ path.to_s, basedir ]
        end
      end
    rescue YAML::Exception
      raise "couldn't parse #{path}"
    end.map do |name, params|
      params.merge! options.transform_keys(&:to_s)
      params.merge! config[name] if config[name]
      Layer.new(name, map, params)
    end.tap do |layers|
      map.add *layers, **create_options
    ensure
      map.save
    end
  end

  def self.grid(archive, options, config)
    add archive, "Grid", options, config
  end

  def self.declination(archive, options, config)
    add archive, "Declination", options, config
  end

  def self.remove(archive, *names, options, config)
    map = Map.new(archive)
    names.uniq.map do |name|
      name.gsub ?/, ?.
    end.map do |name|
      name[?*] ? %r[^#{name.gsub ?*, '.*'}$] : name
    end.tap do |names|
      raise "no matching layers found" unless map.remove(*names)
    end
    map.save
  end

  def self.render(archive, format, *formats, options, config)
    map = Map.new(archive)
    # TODO: render various output formats
  end
end

  # extend Dither

#   SEGMENT = ?.
#   MM_DECIMAL_DIGITS = 4
#   EARTH_RADIUS = 6378137.0

#   WINDOWS = !RbConfig::CONFIG["host_os"][/mswin|mingw/].nil?
#   OP = WINDOWS ? "(" : "\("
#   CP = WINDOWS ? ")" : "\)"
#   ZIP = WINDOWS ? "7z a -tzip" : "zip"
#   DISCARD_STDERR = WINDOWS ? "2> nul" : "2>/dev/null"

#   InternetError = Class.new(Exception)
#   ServerError = Class.new(Exception)
#   BadLayerError = Class.new(Exception)
#   NoVectorPDF = Class.new(Exception)

#   CONFIG = Config.new

#   def self.run(config)
#     CONFIG.finalise config

#     relief_masks = []
#     layers = Enumerator.new do |yielder|
#       includes = CONFIG["include"].map do |name_or_path_or_hash|
#         [ *name_or_path_or_hash ].flatten
#       end
#       while includes.any?
#         name_or_path, resolution, basedir = includes.shift
#         params = resolution ? { "resolution" => resolution } : { }
#         case name_or_path
#         when "grid"
#           yielder << [ name_or_path, params.merge("class" => "GridLayer") ]
#         when "declination"
#           yielder << [ name_or_path, params.merge("class" => "DeclinationLayer") ]
#         when "controls"
#           yielder << [ name_or_path, params.merge("class" => "ControlsLayer") ]
#         when /\.(tiff?|png|jpg)$/i
#           path = Pathname(name_or_path)
#           yielder << [ path.basename(path.extname).to_s, params.merge("class" => "ImportLayer", "path" => path)]
#         when /\.(kml|gpx)$/i
#           path = Pathname(name_or_path)
#           yielder << [ path.basename(path.extname).to_s, params.merge("class" => "OverlayLayer", "path" => path) ]
#         when /\.yml$/i
#           includes << [ Pathname(name_or_path), resolution, basedir ]
#         when String
#           includes << [ Pathname(name_or_path + ".yml"), resolution, basedir ]
#         when Pathname
#           path = [ nil, Pathname.new(__dir__).parent + "layers" ].map do |root|
#             name_or_path.expand_path *root
#           end.find(&:file?)
#           abort "Error: couldn't find layer for '#{name_or_path}'" unless path
#           basedir ||= path.parent
#           contents = YAML.load_file path rescue nil
#           case contents
#           when Array
#             contents.each do |relative_path|
#               includes << [ Pathname(relative_path).expand_path(path.parent).to_s, resolution, basedir ]
#             end
#           when Hash
#             name = path.relative_path_from(basedir).descend.map(&:basename).join(SEGMENT)
#             yielder << [ name, contents.merge(params).merge("sourcedir" => path.parent) ]
#           else
#             abort "Error: couldn't process layer for '#{name_or_path}'"
#           end
#         end
#       end
#     end.to_a.each do |name, params|
#       params.deep_merge! CONFIG[name] if CONFIG[name]
#       [ *params["relief-mask"] ].each do |sublayer|
#         relief_masks << [ name, *(sublayer unless sublayer == true) ].join(SEGMENT)
#       end
#     end.each do |name, params|
#       params.merge!("masks" => relief_masks) if "ReliefLayer" == params["class"]
#     end.map do |name, params|
#       NSWTopo.const_get(params.delete "class").new(name, params)
#     end

#     # CONFIG["contour-interval"].tap do |interval|
#     #   interval ||= CONFIG.map.scale < 40000 ? 10 : 20
#     #   layers.each do |name, klass, params|
#     #     params["exclude"] = [ *params["exclude"] ]
#     #     [ *params["intervals-contours"] ].select do |candidate, sublayers|
#     #       candidate != interval
#     #     end.map(&:last).each do |sublayers|
#     #       params["exclude"] += [ *sublayers ]
#     #     end
#     #   end
#     # end

#     # CONFIG["exclude"].each do |group_or_layer_name|
#     #   layers.reject! do |name, klass, params|
#     #     name == group_or_layer_name
#     #   end
#     #   layers.each do |name, klass, params|
#     #     match = group_or_layer_name.match %r[^#{name}#{SEGMENT}(.+)]
#     #     params["exclude"] << match[1] if match
#     #   end
#     # end

#     layers.each do |layer|
#       begin
#         layer.create if layer.respond_to?(:create)
#       rescue InternetError, ServerError, BadLayerError => e
#         $stderr.puts "Error: #{e.message}" and next
#       end
#     end

#     return if CONFIG["no-output"]

#     svg_name = "#{CONFIG.map.filename}.svg"
#     svg_path = Pathname.pwd + svg_name

#     unless CONFIG["no-update"]
#       xml = svg_path.exist? ? REXML::Document.new(svg_path.read) : CONFIG.map.xml

#       removals = CONFIG["exclude"].select do |name|
#         predicate = "@id='#{name}' or starts-with(@id,'#{name}#{SEGMENT}')"
#         xml.elements["/svg/g[#{predicate}] | svg/defs/[#{predicate}]"]
#       end

#       updates = layers.reject do |layer|
#         layer.respond_to?(:path) ? FileUtils.uptodate?(svg_path, [ *layer.path ]) : xml.elements["/svg/g[@id='#{layer.name}' or starts-with(@id,'#{layer.name}#{SEGMENT}')]"]
#       end

#       Dir.mktmppath do |temp_dir|
#         if updates.any? do |layer|
#           layer.respond_to? :labels
#         end || removals.any? do |name|
#           xml.elements["/svg/g[@id='labels#{SEGMENT}#{name}']"]
#         end then
#           label_layer = LabelLayer.new unless CONFIG["no-labels"]
#         end

#         CONFIG["exclude"].map do |name|
#           predicate = "@id='#{name}' or starts-with(@id,'#{name}#{SEGMENT}') or @id='labels#{SEGMENT}#{name}' or starts-with(@id,'labels#{SEGMENT}#{name}#{SEGMENT}')"
#           xpath = "/svg/g[#{predicate}] | svg/defs/[#{predicate}]"
#           if xml.elements[xpath]
#             puts "Removing: #{name}"
#             xml.elements.each(xpath, &:remove)
#           end
#         end

#         [ *updates, *label_layer ].each do |layer|
#           begin
#             if layer == label_layer
#               puts "Processing label data:"
#               Font.configure
#               layers.each do |layer|
#                 label_layer.add(layer) do |sublayer|
#                   puts "  #{[ layer.name, *sublayer ].join SEGMENT}"
#                 end
#               end
#             end
#             puts "Compositing: #{layer.name}"
#             predicate = "@id='#{layer.name}' or starts-with(@id,'#{layer.name}#{SEGMENT}')"
#             xml.elements.each("/svg/g[#{predicate}]/*", &:remove)
#             xml.elements.each("/svg/defs/[#{predicate}]", &:remove)
#             preexisting = xml.elements["/svg/g[#{predicate}]"]
#             layer.render_svg(xml) do |sublayer|
#               id = [ layer.name, *sublayer ].join(SEGMENT)
#               if preexisting
#                 xml.elements["/svg/g[@id='#{id}']"]
#               else
#                 before, after = layers.map(&:name).inject([[]]) do |memo, name|
#                   name == layer.name ? memo << [] : memo.last << name
#                   memo
#                 end
#                 neighbour = xml.elements.collect("/svg/g[@id]") do |sibling|
#                   sibling if [ *after ].any? do |name|
#                     sibling.attributes["id"] == name || sibling.attributes["id"].start_with?("#{name}#{SEGMENT}")
#                   end
#                 end.compact.first
#                 REXML::Element.new("g").tap do |group|
#                   group.add_attributes "id" => id, "style" => "opacity:1"
#                   neighbour ? xml.elements["/svg"].insert_before(neighbour, group) : xml.elements["/svg"].add_element(group)
#                 end
#               end
#             end
#           rescue BadLayerError => e
#             puts "Failed to render #{layer.name}: #{e.message}"
#           end
#         end

#         xml.elements.each("/svg/g[*]") { |group| group.add_attribute("inkscape:groupmode", "layer") }

#         tmp_svg_path = temp_dir + svg_name
#         tmp_svg_path.open("w") do |file|
#           formatter = REXML::Formatters::Pretty.new
#           formatter.compact = true
#           formatter.write xml, file
#         end

#         FileUtils.cp tmp_svg_path, svg_path
#       end if updates.any? || removals.any?
#     end

#     formats = [ *CONFIG["formats"] ].map { |format| [ *format ].flatten }.inject({}) { |memo, (format, option)| memo.merge format => option }
#     formats["prj"] = %w[wkt_all proj4 wkt wkt_simple wkt_noct wkt_esri mapinfo xml].delete(formats["prj"]) || "proj4" if formats.include? "prj"
#     formats["png"] ||= nil if formats.include? "map"
#     (formats.keys & %w[png tif gif jpg kmz mbtiles zip psd]).each do |format|
#       formats[format] ||= CONFIG["ppi"]
#     end
#     (formats.keys & %w[png tif gif jpg]).each do |format|
#       formats["#{format[0]}#{format[2]}w"] = formats[format]
#     end if formats.include? "prj"

#     outstanding = (formats.keys & %w[png tif gif jpg kmz mbtiles zip psd pdf pgw tfw gfw jgw map prj]).reject do |format|
#       FileUtils.uptodate? "#{CONFIG.map.filename}.#{format}", [ svg_path ]
#     end

#     Dir.mktmppath do |temp_dir|
#       outstanding.group_by do |format|
#         [ formats[format], format == "mbtiles" ]
#       end.each do |(ppi, mbtiles), group|
#         png_path = temp_dir + "#{CONFIG.map.filename}.#{ppi}.png"
#         if (group & %w[png tif gif jpg kmz zip psd]).any? || (ppi && group.include?("pdf"))
#           Raster.build ppi, svg_path, temp_dir, png_path do |dimensions|
#             puts "Generating raster: %ix%i (%.1fMpx) @ %i ppi" % [ *dimensions, 0.000001 * dimensions.inject(:*), ppi ]
#           end
#           dither png_path if CONFIG["dither"]
#         end
#         group.each do |format|
#           begin
#             puts "Generating #{CONFIG.map.filename}.#{format}"
#             output_path = temp_dir + "#{CONFIG.map.filename}.#{format}"
#             case format
#             when "png"
#               FileUtils.cp png_path, output_path
#             when "tif"
#               %x[gdal_translate -a_srs "#{CONFIG.map.projection}" -co PROFILE=GeoTIFF -co COMPRESS=DEFLATE -co ZLEVEL=9 -co TILED=YES -mo TIFFTAG_RESOLUTIONUNIT=2 -mo "TIFFTAG_XRESOLUTION=#{ppi}" -mo "TIFFTAG_YRESOLUTION=#{ppi}" -mo TIFFTAG_SOFTWARE=nswtopo -mo "TIFFTAG_DOCUMENTNAME=#{CONFIG.map.name}" "#{png_path}" "#{output_path}" #{DISCARD_STDERR}]
#             when "gif", "jpg"
#               %x[convert "#{png_path}" "#{output_path}"]
#             when "kmz"
#               KMZ.build ppi, png_path, output_path
#             when "mbtiles"
#               MBTiles.build ppi, svg_path, temp_dir, output_path
#             when "zip"
#               Avenza.build ppi, png_path, temp_dir, output_path
#             when "psd"
#               PSD.build ppi, svg_path, png_path, temp_dir, output_path
#             when "pdf"
#               PDF.build ppi, ppi ? png_path : svg_path, temp_dir, output_path
#             when "pgw", "tfw", "gfw", "jgw"
#               CONFIG.map.write_world_file output_path, CONFIG.map.resolution_at(ppi)
#             when "map"
#               CONFIG.map.write_oziexplorer_map output_path, CONFIG.map.name, "#{CONFIG.map.filename}.png", formats["png"]
#             when "prj"
#               File.write output_path, CONFIG.map.projection.send(formats["prj"])
#             end
#             FileUtils.cp output_path, Dir.pwd
#           rescue NoVectorPDF => e
#             puts "Error: can't generate vector PDF with #{e.message}. Specify a ppi for the PDF or use inkscape. (See README.)"
#           end
#         end
#       end
#     end unless outstanding.empty?
#   end
# end

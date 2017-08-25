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

require_relative 'helpers'
require_relative 'avl_tree'
require_relative 'geometry'
require_relative 'nswtopo/config'
require_relative 'nswtopo/helpers'
require_relative 'nswtopo/gps'
require_relative 'nswtopo/projection'
require_relative 'nswtopo/map'
require_relative 'nswtopo/esri_hdr'
require_relative 'nswtopo/font'
require_relative 'nswtopo/formats'
require_relative 'nswtopo/sources'

NSWTOPO_VERSION = "1.5"

module NSWTopo
  extend Dither
  
  SEGMENT = ?.
  MM_DECIMAL_DIGITS = 4
  EARTH_RADIUS = 6378137.0

  WINDOWS = !RbConfig::CONFIG["host_os"][/mswin|mingw/].nil?
  OP = WINDOWS ? '(' : '\('
  CP = WINDOWS ? ')' : '\)'
  ZIP = WINDOWS ? "7z a -tzip" : "zip"
  DISCARD_STDERR = WINDOWS ? "2> nul" : "2>/dev/null"

  InternetError = Class.new(Exception)
  ServerError = Class.new(Exception)
  BadGpxKmlFile = Class.new(Exception)
  BadLayerError = Class.new(Exception)
  NoVectorPDF = Class.new(Exception)

  CONFIG = Config.new

  def self.run(config)
    CONFIG.finalise config

    puts "Map details:"
    puts "  name: #{CONFIG.map.name}"
    puts "  size: %imm x %imm" % CONFIG.map.extents.map { |extent| 1000 * extent / CONFIG.map.scale }
    puts "  scale: 1:%i" % CONFIG.map.scale
    puts "  rotation: %.1f degrees" % CONFIG.map.rotation
    puts "  extent: %.1fkm x %.1fkm" % CONFIG.map.extents.map { |extent| 0.001 * extent }

    sources = CONFIG["include"].map do |name_or_path_or_hash|
      [ *name_or_path_or_hash ].flatten
    end.map do |name_or_path, resolution|
      params = resolution ? { "resolution" => resolution } : { }
      case name_or_path
      when "canvas"      then [ "canvas",      CanvasSource,      params ]
      when "grid"        then [ "grid",        GridSource,        params ]
      when "declination" then [ "declination", DeclinationSource, params ]
      when "controls"    then [ "controls",    ControlSource,     params ]
      when /\.kml$|\.gpx$/i
        path = Pathname.new(name_or_path).expand_path
        [ path.basename(path.extname).to_s, OverlaySource, params.merge("path" => path) ]
      when /\.yml$/i
        path = Pathname.new(name_or_path)
        params = YAML.load(path.read).merge(params) rescue nil
        abort "Error: couldn't find source for '#{name_or_path}'" unless params
        [ path.basename(path.extname).to_s, NSWTopo.const_get(params.delete "class"), params ]
      else
        yaml = [ Pathname.pwd, Pathname.new(__dir__).parent + "sources" ].map do |root|
          root + "#{name_or_path}.yml"
        end.inject(nil) do |memo, path|
          memo ||= path.read rescue nil
        end
        abort "Error: couldn't find source for '#{name_or_path}'" unless yaml
        params = YAML.load(yaml).merge(params)
        [ name_or_path.gsub(?/, SEGMENT), NSWTopo.const_get(params.delete "class"), params ]
      end
    end

    [ *CONFIG["import"] ].reverse.map do |file_or_hash|
      [ *file_or_hash ].flatten
    end.map do |file_or_path, name|
      [ Pathname.new(file_or_path).expand_path, name ]
    end.each do |path, name|
      name ||= path.basename(path.extname).to_s
      sources.unshift [ name, ImportSource, "path" => path ]
    end

    sources.each do |name, klass, params|
      CONFIG.keys.map do |key|
        [ key.match(%r[^#{name}#{SEGMENT}(.+)]), key ]
      end.select(&:first).map do |match, key|
        [ match[1], CONFIG[key] ]
      end.to_h.tap do |layers_params|
        params.deep_merge! layers_params
      end
    end

    sources.select do |name, klass, params|
      CONFIG[name]
    end.each do |name, klass, params|
      params.deep_merge! CONFIG[name]
    end

    sources.select do |name, klass, params|
      ReliefSource == klass
    end.each do |name, klass, params|
      params["masks"] = sources.map do |name, klass, params|
        [ *params["relief-masks"] ].map { |sublayer| [ name, sublayer ].join SEGMENT }
      end.inject(&:+)
    end

    CONFIG["contour-interval"].tap do |interval|
      interval ||= CONFIG.map.scale < 40000 ? 10 : 20
      sources.each do |name, klass, params|
        params["exclude"] = [ *params["exclude"] ]
        [ *params["intervals-contours"] ].select do |candidate, sublayers|
          candidate != interval
        end.map(&:last).each do |sublayers|
          params["exclude"] += [ *sublayers ]
        end
      end
    end

    CONFIG["exclude"].each do |source_or_layer_name|
      sources.reject! do |name, klass, params|
        name == source_or_layer_name
      end
      sources.each do |name, klass, params|
        match = source_or_layer_name.match %r[^#{name}#{SEGMENT}(.+)]
        params["exclude"] << match[1] if match
      end
    end

    sources.find do |name, klass, params|
      params.fetch("min-version", NSWTOPO_VERSION).to_s > NSWTOPO_VERSION
    end.tap do |name, klass, params|
      abort "Error: map source '#{name}' requires a newer version of this software; please upgrade." if name
    end

    sources.map! do |name, klass, params|
      klass.new(name, params)
    end

    sources.each do |source|
      begin
        source.create if source.respond_to?(:create)
      rescue InternetError, ServerError, BadLayerError => e
        $stderr.puts "Error: #{e.message}" and next
      end
    end

    return if CONFIG["no-output"]

    svg_name = "#{CONFIG.map.filename}.svg"
    svg_path = Pathname.pwd + svg_name

    unless CONFIG["no-update"]
      xml = svg_path.exist? ? REXML::Document.new(svg_path.read) : CONFIG.map.xml

      removals = CONFIG["exclude"].select do |name|
        predicate = "@id='#{name}' or starts-with(@id,'#{name}#{SEGMENT}')"
        xml.elements["/svg/g[#{predicate}] | svg/defs/[#{predicate}]"]
      end

      updates = sources.reject do |source|
        source.respond_to?(:path) ? FileUtils.uptodate?(svg_path, [ *source.path ]) : xml.elements["/svg/g[@id='#{source.name}' or starts-with(@id,'#{source.name}#{SEGMENT}')]"]
      end

      Dir.mktmppath do |temp_dir|
        if updates.any? do |source|
          source.respond_to? :labels
        end || removals.any? do |name|
          xml.elements["/svg/g[@id='labels#{SEGMENT}#{name}']"]
        end then
          label_source = LabelSource.new unless CONFIG["no-labels"]
        end

        CONFIG["exclude"].map do |name|
          predicate = "@id='#{name}' or starts-with(@id,'#{name}#{SEGMENT}') or @id='labels#{SEGMENT}#{name}' or starts-with(@id,'labels#{SEGMENT}#{name}#{SEGMENT}')"
          xpath = "/svg/g[#{predicate}] | svg/defs/[#{predicate}]"
          if xml.elements[xpath]
            puts "Removing: #{name}"
            xml.elements.each(xpath, &:remove)
          end
        end

        [ *updates, *label_source ].each do |source|
          begin
            if source == label_source
              puts "Processing label data:"
              sources.each do |source|
                label_source.add(source) do |sublayer|
                  puts "  #{[ source.name, *sublayer ].join SEGMENT}"
                end
              end
            end
            puts "Compositing: #{source.name}"
            predicate = "@id='#{source.name}' or starts-with(@id,'#{source.name}#{SEGMENT}')"
            xml.elements.each("/svg/g[#{predicate}]/*", &:remove)
            xml.elements.each("/svg/defs/[#{predicate}]", &:remove)
            preexisting = xml.elements["/svg/g[#{predicate}]"]
            source.render_svg(xml) do |sublayer|
              id = [ source.name, *sublayer ].join(SEGMENT)
              if preexisting
                xml.elements["/svg/g[@id='#{id}']"]
              else
                before, after = sources.map(&:name).inject([[]]) do |memo, name|
                  name == source.name ? memo << [] : memo.last << name
                  memo
                end
                neighbour = xml.elements.collect("/svg/g[@id]") do |sibling|
                  sibling if [ *after ].any? do |name|
                    sibling.attributes["id"] == name || sibling.attributes["id"].start_with?("#{name}#{SEGMENT}")
                  end
                end.compact.first
                REXML::Element.new("g").tap do |group|
                  group.add_attributes "id" => id, "style" => "opacity:1"
                  neighbour ? xml.elements["/svg"].insert_before(neighbour, group) : xml.elements["/svg"].add_element(group)
                end
              end
            end
          rescue BadLayerError => e
            puts "Failed to render #{source.name}: #{e.message}"
          end
        end

        xml.elements.each("/svg/g[*]") { |group| group.add_attribute("inkscape:groupmode", "layer") }

        if CONFIG["check-fonts"]
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

        tmp_svg_path = temp_dir + svg_name
        tmp_svg_path.open("w") do |file|
          formatter = REXML::Formatters::Pretty.new
          formatter.compact = true
          formatter.write xml, file
        end
        FileUtils.cp tmp_svg_path, svg_path
      end if updates.any? || removals.any?
    end

    formats = [ *CONFIG["formats"] ].map { |format| [ *format ].flatten }.inject({}) { |memo, (format, option)| memo.merge format => option }
    formats["prj"] = %w[wkt_all proj4 wkt wkt_simple wkt_noct wkt_esri mapinfo xml].delete(formats["prj"]) || "proj4" if formats.include? "prj"
    formats["png"] ||= nil if formats.include? "map"
    (formats.keys & %w[png tif gif jpg kmz mbtiles zip psd]).each do |format|
      formats[format] ||= CONFIG["ppi"]
    end
    (formats.keys & %w[png tif gif jpg]).each do |format|
      formats["#{format[0]}#{format[2]}w"] = formats[format]
    end if formats.include? "prj"

    outstanding = (formats.keys & %w[png tif gif jpg kmz mbtiles zip psd pdf pgw tfw gfw jgw map prj]).reject do |format|
      FileUtils.uptodate? "#{CONFIG.map.filename}.#{format}", [ svg_path ]
    end

    Dir.mktmppath do |temp_dir|
      outstanding.group_by do |format|
        [ formats[format], format == "mbtiles" ]
      end.each do |(ppi, mbtiles), group|
        png_path = temp_dir + "#{CONFIG.map.filename}.#{ppi}.png"
        if (group & %w[png tif gif jpg kmz zip psd]).any? || (ppi && group.include?("pdf"))
          Raster.build ppi, svg_path, temp_dir, png_path do |dimensions|
            puts "Generating raster: %ix%i (%.1fMpx) @ %i ppi" % [ *dimensions, 0.000001 * dimensions.inject(:*), ppi ]
          end
          dither png_path if CONFIG["dither"]
        end
        group.each do |format|
          begin
            puts "Generating #{CONFIG.map.filename}.#{format}"
            output_path = temp_dir + "#{CONFIG.map.filename}.#{format}"
            case format
            when "png"
              FileUtils.cp png_path, output_path
            when "tif"
              %x[gdal_translate -a_srs "#{CONFIG.map.projection}" -co PROFILE=GeoTIFF -co COMPRESS=DEFLATE -co ZLEVEL=9 -co TILED=YES -mo TIFFTAG_RESOLUTIONUNIT=2 -mo "TIFFTAG_XRESOLUTION=#{ppi}" -mo "TIFFTAG_YRESOLUTION=#{ppi}" -mo TIFFTAG_SOFTWARE=nswtopo -mo "TIFFTAG_DOCUMENTNAME=#{CONFIG.map.name}" "#{png_path}" "#{output_path}"]
            when "gif", "jpg"
              %x[convert "#{png_path}" "#{output_path}"]
            when "kmz"
              KMZ.build ppi, png_path, output_path
            when "mbtiles"
              MBTiles.build ppi, svg_path, temp_dir, output_path
            when "zip"
              Avenza.build ppi, png_path, temp_dir, output_path
            when "psd"
              PSD.build ppi, svg_path, png_path, temp_dir, output_path
            when "pdf"
              ppi ? %x[convert "#{png_path}" "#{output_path}"] : PDF.build(svg_path, temp_dir, output_path)
            when "pgw", "tfw", "gfw", "jgw"
              CONFIG.map.write_world_file output_path, CONFIG.map.resolution_at(ppi)
            when "map"
              CONFIG.map.write_oziexplorer_map output_path, CONFIG.map.name, "#{CONFIG.map.filename}.png", formats["png"]
            when "prj"
              File.write output_path, CONFIG.map.projection.send(formats["prj"])
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

# TODO: check georeferencing of aerial-google, aerial-nokia

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
require_relative 'nswtopo/formats'
require_relative 'nswtopo/map'
require_relative 'nswtopo/layer'

module NSWTopo
  PartialFailureError = Class.new RuntimeError

  def self.init(archive, config, options)
    map = Map.init archive, config, options
    map.save
    puts map
  end

  def self.info(archive, config, options)
    puts Map.load(archive, config).info(options)
  end

  def self.add(archive, config, layer, after: nil, before: nil, overwrite: nil, **options)
    create_options = {
      after: Layer.sanitise(after),
      before: Layer.sanitise(before),
      overwrite: overwrite
    }
    map = Map.load archive, config
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

  def self.grid(archive, config, options)
    add archive, config, "Grid", options
  end

  def self.declination(archive, config, options)
    add archive, config, "Declination", options
  end

  def self.remove(archive, config, *names, options)
    map = Map.load archive, config
    names.uniq.map do |name|
      Layer.sanitise name
    end.map do |name|
      name[?*] ? %r[^#{name.gsub(?., '\.').gsub(?*, '.*')}$] : name
    end.tap do |names|
      raise "no matching layers found" unless map.remove(*names)
    end
    map.save
  end

  def self.clean(archive, config, options)
    Map.load(archive, config).clean
  end

  def self.render(archive, config, format, *formats, options)
    overwrite = options.delete :overwrite
    [ format, *formats ].uniq.map do |format|
      Pathname(Formats === format ? "#{archive.basename}.#{format}" : format)
    end.each do |path|
      format = path.extname.delete_prefix(?.)
      raise "unrecognised format: #{path}" if format.empty?
      raise "unrecognised format: #{format}" unless Formats === format
      raise "file already exists: #{path}" if path.exist? && !overwrite
      raise "non-existent directory: #{path.parent}" unless path.parent.directory?
    end.tap do |paths|
      Map.load(archive, config).render *paths, **options
    end
  end

  def self.layers(state: nil, root: nil, indent: "")
    directory = [ Pathname(__dir__).parent, "layers", *state ].inject(&:/)
    root ||= directory
    directory.children.sort.each do |path|
      case
      when path.directory?
        puts [ indent, path.relative_path_from(root) ].join
        layers state: [ *state, path.basename ], root: root, indent: indent + "  "
      when path.sub_ext("").directory?
      when path.extname == ".yml"
        puts [ indent, path.relative_path_from(root).sub_ext("") ].join
      end
    end
  end
end

# # TODO: re-implement relief masks:
#     relief_masks = []
#       [ *params["relief-mask"] ].each do |sublayer|
#         relief_masks << [ name, *(sublayer unless sublayer == true) ].join(SEGMENT)
#       end
#     end.each do |name, params|
#       params.merge!("masks" => relief_masks) if "ReliefLayer" == params["class"]

# # TODO: re-implement intervals-contours? (a better way?):
# CONFIG["contour-interval"].tap do |interval|
#   interval ||= CONFIG.map.scale < 40000 ? 10 : 20
#   layers.each do |name, klass, params|
#     params["exclude"] = [ *params["exclude"] ]
#     [ *params["intervals-contours"] ].select do |candidate, sublayers|
#       candidate != interval
#     end.map(&:last).each do |sublayers|
#       params["exclude"] += [ *sublayers ]
#     end
#   end
# end


# if updates.any? do |layer|
#   layer.respond_to? :labels
# end || removals.any? do |name|
#   xml.elements["/svg/g[@id='labels#{SEGMENT}#{name}']"]
# end then
#   label_layer = LabelLayer.new unless CONFIG["no-labels"]
# end


# Dir.mktmppath do |temp_dir|
#   outstanding.group_by do |format|
#     [ formats[format], format == "mbtiles" ]
#   end.each do |(ppi, mbtiles), group|
#     png_path = temp_dir + "#{CONFIG.map.filename}.#{ppi}.png"
#     if (group & %w[png tif gif jpg kmz zip psd]).any? || (ppi && group.include?("pdf"))
#       Raster.build ppi, svg_path, temp_dir, png_path do |dimensions|
#         puts "Generating raster: %ix%i (%.1fMpx) @ %i ppi" % [ *dimensions, 0.000001 * dimensions.inject(:*), ppi ]
#       end
#       dither png_path if CONFIG["dither"]
#     end
#     group.each do |format|
#       begin
#         puts "Generating #{CONFIG.map.filename}.#{format}"
#         output_path = temp_dir + "#{CONFIG.map.filename}.#{format}"
#         case format
#         when "png"
#           FileUtils.cp png_path, output_path
#         when "tif"
#           %x[gdal_translate -a_srs "#{CONFIG.map.projection}" -co PROFILE=GeoTIFF -co COMPRESS=DEFLATE -co ZLEVEL=9 -co TILED=YES -mo TIFFTAG_RESOLUTIONUNIT=2 -mo "TIFFTAG_XRESOLUTION=#{ppi}" -mo "TIFFTAG_YRESOLUTION=#{ppi}" -mo TIFFTAG_SOFTWARE=nswtopo -mo "TIFFTAG_DOCUMENTNAME=#{CONFIG.map.name}" "#{png_path}" "#{output_path}" #{DISCARD_STDERR}]
#         when "gif", "jpg"
#           %x[convert "#{png_path}" "#{output_path}"]
#         when "kmz"
#           KMZ.build ppi, png_path, output_path
#         when "mbtiles"
#           MBTiles.build ppi, svg_path, temp_dir, output_path
#         when "zip"
#           Avenza.build ppi, png_path, temp_dir, output_path
#         when "psd"
#           PSD.build ppi, svg_path, png_path, temp_dir, output_path
#         when "pdf"
#           PDF.build ppi, ppi ? png_path : svg_path, temp_dir, output_path
#         when "pgw", "tfw", "gfw", "jgw"
#           CONFIG.map.write_world_file output_path, CONFIG.map.resolution_at(ppi)
#         when "map"
#           CONFIG.map.write_oziexplorer_map output_path, CONFIG.map.name, "#{CONFIG.map.filename}.png", formats["png"]
#         when "prj"
#           File.write output_path, CONFIG.map.projection.send(formats["prj"])
#         end
#         FileUtils.cp output_path, Dir.pwd
#       rescue NoVectorPDF => e
#         puts "Error: can't generate vector PDF with #{e.message}. Specify a ppi for the PDF or use inkscape. (See README.)"
#       end
#     end
#   end
# end unless outstanding.empty?

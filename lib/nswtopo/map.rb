module NSWTopo
  class Map
    include Formats, Dither, Zip, Log, Safely, TiledWebMap

    def initialize(archive, neatline:, centre:, dimensions:, scale:, rotation:, layers: {})
      @archive, @neatline, @centre, @dimensions, @scale, @rotation, @layers = archive, neatline, centre, dimensions, scale, rotation, layers
      params = { k_0: 1.0 / @scale, units: "mm", x_0: 0.0005 * @dimensions[0], y_0: 0.0005 * @dimensions[1] }
      @projection = rotation.zero? ?
        Projection.transverse_mercator(*centre, **params) :
        Projection.oblique_mercator(*centre, alpha: rotation, **params)
      @cutline = @neatline.reproject_to(@projection)
    end
    attr_reader :centre, :dimensions, :scale, :rotation, :projection

    extend Forwardable
    delegate %i[write mtime read uptodate?] => :@archive

    def self.init(archive, scale: 25000, rotation: 0.0, bounds: nil, coords: nil, dimensions: nil, inset: [0, 0], margins: nil)
      points = case
      when dimensions && margins
        raise "can't specify both margins and map dimensions"
      when coords && bounds
        raise "can't specify both bounds file and map coordinates"
      when coords
        coords
      when bounds
        gps = GPS.load(bounds).explode
        margins ||= [15, 15] unless dimensions || gps.polygons.any?
        case
        when gps.polygons.any?
          gps.polygons.flat_map(&:coordinates).inject(&:+)
        when gps.linestrings.any?
          gps.linestrings.map(&:coordinates).inject(&:+)
        when gps.points.any?
          gps.points.map(&:coordinates)
        else
          raise "no features found in %s" % bounds
        end
      else
        raise "no bounds file or map coordinates specified"
      end
      margins ||= [0, 0]

      centre = points.transpose.map(&:minmax).map(&:sum).times(0.5)
      equidistant = Projection.azimuthal_equidistant *centre

      case rotation
      when "auto"
        raise "can't specify both map dimensions and auto-rotation" if dimensions
        local_points = GeoJSON.multipoint(points).reproject_to(equidistant).coordinates
        local_centre, local_extents, rotation = local_points.minimum_bounding_box(*margins)
        rotation *= -180.0 / Math::PI
      when "magnetic"
        rotation = declination(*centre)
      else
        raise "map rotation must be between ±45°" unless rotation.abs <= 45
      end

      unless dimensions || local_centre
        local_points = GeoJSON.multipoint(points).reproject_to(equidistant).coordinates
        local_centre, local_extents = local_points.map do |point|
          point.rotate_by_degrees rotation
        end.transpose.map(&:minmax).map do |min, max|
          [0.5 * (max + min), max - min]
        end.transpose
        local_centre.rotate_by_degrees! -rotation
      end

      unless dimensions
        dimensions = local_extents.times(1000.0 / scale).plus margins.times(2)
        centre = GeoJSON.point(local_centre, projection: equidistant).reproject_to_wgs84.coordinates
      end

      params = { units: "mm", axis: "esu", k_0: 1.0 / scale, x_0: 0.0005 * dimensions[0], y_0: -0.0005 * dimensions[1] }
      projection = rotation.zero? ?
        Projection.transverse_mercator(*centre, **params) :
        Projection.oblique_mercator(*centre, alpha: rotation, **params)

      case
      when dimensions.all?(&:positive?)
      when coords
        raise "not enough information to calculate map size – add more coordinates, or specify map dimensions or margins"
      when bounds
        raise "not enough information to calculate map size – check bounds file, or specify map dimensions or margins"
      end

      dimensions.zip(inset).map do |dimension, inset|
        raise OptionParser::InvalidArgument, "inset larger than map dimension" unless inset.abs < dimension
        inset > 0 ? [0, dimension - inset, dimension] : [0, 0 - inset, dimension]
      end.inject(&:product).then do |points|
        case
        when inset[0] > 0 && inset[1] > 0 then points.values_at(0,6,7,4,5,2,0)
        when inset[0] > 0 && inset[1] < 0 then points.values_at(0,3,4,7,8,2,0)
        when inset[0] < 0 && inset[1] > 0 then points.values_at(0,6,8,5,4,1,0)
        when inset[0] < 0 && inset[1] < 0 then points.values_at(3,6,8,2,1,4,3)
        else                                   points.values_at(0,6,8,2,0)
        end
      end.then do |ring|
        GeoJSON.polygon [ring], projection: projection
      end.then do |neatline|
        new(archive, neatline: neatline, centre: centre, dimensions: dimensions, scale: scale, rotation: rotation).save
      end
    end

    def self.load(archive)
      properties = YAML.load(archive.read "map.yml")
      neatline = GeoJSON::Collection.load(archive.read "map.json")
      new archive, neatline: neatline, **properties
    rescue ArgumentError, YAML::Exception, GeoJSON::Error
      raise NSWTopo::Archive::Invalid
    end

    def save
      tap do
        write "map.json", @neatline.to_json
        write "map.yml", YAML.dump(centre: @centre, dimensions: @dimensions, scale: @scale, rotation: @rotation, layers: @layers)
      end
    end

    def self.from_svg(archive, svg_path)
      xml = REXML::Document.new(svg_path.read)

      creator_tool = xml.elements["svg/metadata/rdf:RDF/rdf:Description[@xmp:CreatorTool]/@xmp:CreatorTool"]&.value
      version = Version[creator_tool]
      raise "SVG nswtopo version too old: %s" % svg_path unless version >= MIN_VERSION
      raise "SVG nswtopo version too new: %s" % svg_path unless version <= VERSION

      /^0\s+0\s+(?<width>\S+)\s+(?<height>\S+)$/ =~ xml.elements["svg[@viewBox]/@viewBox"]&.value
       width && xml.elements["svg[ @width='#{ width}mm']"] || raise(Version::Error)
      height && xml.elements["svg[@height='#{height}mm']"] || raise(Version::Error)
      dimensions = [width, height].map(&:to_f)

      metadata = xml.elements["svg/metadata/nswtopo:map[@projection][@centre][@scale][@rotation]"] || raise(Version::Error)
      projection = Projection.new metadata.attributes["projection"]
      centre = metadata.attributes["centre"].split(?,).map(&:to_f)
      scale = metadata.attributes["scale"].to_i
      rotation = metadata.attributes["rotation"].to_f

      path = xml.elements["svg/defs/path[@id='map.neatline'][@d]"] || raise(Version::Error)
      neatline = path.attributes["d"].delete_prefix("M ").delete_suffix(" Z").split(" L ").map do |pair|
        pair.split(" ").map(&:to_f)
      end.then do |ring|
        GeoJSON.polygon [ring], projection: projection
      end

      new(archive, neatline: neatline, centre: centre, dimensions: dimensions, scale: scale, rotation: rotation).save.tap do |map|
        map.write "map.svg", svg_path.read
      end
    rescue Version::Error
      raise "not an nswtopo SVG file: %s" % svg_path
    rescue SystemCallError
      raise "couldn't read file: %s" % svg_path
    rescue REXML::ParseException
      raise "unrecognised map file: %s" % svg_path
    end

    def layers
      @layers.map do |name, params|
        Layer.new(name, self, params)
      end
    end

    def neatline(mm: nil)
      mm ? @neatline.buffer(mm).explode : @neatline
    end

    def cutline(mm: nil)
      mm ? @cutline.buffer(mm).explode : @cutline
    end

    def to_mm(metres)
      metres * 1000.0 / @scale
    end

    def write_world_file(path, resolution: nil, ppi: nil)
      mm_per_px = ppi ? 25.4 / ppi : to_mm(resolution)
      path.open("w") do |file|
        file.puts mm_per_px, 0, 0, -mm_per_px
        file.puts 0.5 * mm_per_px
        file.puts @dimensions[1] - 0.5 * mm_per_px
      end
    end

    def self.declination(longitude, latitude)
      today = Date.today
      query = { latd: latitude, lond: longitude, latm: 0, lonm: 0, lats: 0, lons: 0, elev: 0, year: today.year, month: today.month, day: today.day, Ein: "Dtrue" }
      uri = URI::HTTPS.build host: "api.geomagnetism.ga.gov.au", path: "/agrf", query: URI.encode_www_form(query)
      json = Net::HTTP.get uri
      Float(JSON.parse(json).dig("magneticFields", "D").to_s.sub(/ .*/, ""))
    rescue JSON::ParserError, ArgumentError, TypeError, SystemCallError, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError
      raise "couldn't get magnetic declination value"
    end

    def declination
      Map.declination *@centre
    end

    def add(*layers, after: nil, before: nil, replace: nil, overwrite: false, strict: false)
      [%w[before after replace], [before, after, replace]].transpose.select(&:last).each do |option, name|
        next if self.layers.any? { |other| other.name == name }
        raise "no such layer: %s" % name
      end.map(&:first).combination(2).each do |options|
        raise OptionParser::AmbiguousOption,  "can't specify --%s and --%s simultaneously" % options
      end

      strict ||= layers.one?
      layers.inject [self.layers, false, replace || after, []] do |(layers, changed, follow, errors), layer|
        index = layers.index layer unless replace || after || before
        if overwrite || !layer.uptodate?
          layer.create
          log_success "%s layer: %s" % [layer.empty? ? "empty" : "added", layer.name]
        else
          log_neutral "kept existing layer: %s" % layer.name
          next layers, changed, layer.name, errors if index
        end
        layers.delete layer
        case
        when index
        when follow
          index = layers.index { |other| other.name == follow }
          index += 1
        when before
          index = layers.index { |other| other.name == before }
        else
          index = layers.index { |other| (other <=> layer) > 0 } || -1
        end
        next layers.insert(index, layer), true, layer.name, errors
      rescue ArcGIS::Connection::Error => error
        log_warn "couldn't download layer: #{layer.name}"
        next layers, changed, follow, errors << error
      rescue RuntimeError => error
        errors << error
        break layers, changed, follow, errors if strict
        log_warn error.message
        next layers, changed, follow, errors
      end.tap do |ordered_layers, changed, follow, errors|
        if changed
          @layers.replace Hash[ordered_layers.map(&:pair)]
          replace ? delete(replace) : save
        end
        case
        when errors.none?
        when strict
          raise errors.first
        when errors.one?
          raise PartialFailureError, "failed to create layer"
        else
          raise PartialFailureError, "failed to create #{errors.length} layers"
        end
      end
    end

    def delete(*names)
      raise OptionParser::MissingArgument, "no layers specified" unless names.any?
      names.inject Set[] do |matched, name|
        matches = @layers.keys.grep(name)
        raise "no such layer: #{name}" if String === name && matches.none?
        matched.merge matches
      end.tap do |names|
        raise "no matching layers found" unless names.any?
      end.each do |name|
        params = @layers.delete name
        @archive.delete Layer.new(name, self, params).filename
        log_success "deleted layer: %s" % name
      end
      save
    end

    def move(name, before: nil, after: nil)
      name, target = [name, before || after].map do |name|
        Layer.sanitise name
      end.each do |name|
        raise OptionParser::InvalidArgument, "no such layer: #{name}" unless @layers.key? name
      end
      raise OptionParser::InvalidArgument, "layers must be different" if name == target
      insert = [name, @layers.delete(name)]
      @layers.each.with_object [] do |(name, layer), layers|
        layers << insert if before && name == target
        layers << [name, layer]
        layers << insert if after && name == target
      end.tap do |layers|
        @layers.replace layers.to_h
      end
      save
    end

    def info(empty: nil, json: false, proj: false, wkt2: false)
      case
      when json
        bbox = @neatline.reproject_to_wgs84.first
        bbox.properties.merge! dimensions: @dimensions, scale: @scale, rotation: @rotation, layers: layers.map(&:name)
        JSON.pretty_generate bbox.to_h
      when proj
        OS.gdalsrsinfo("-o", "proj4", "--single-line", @projection)
      when wkt2
        OS.gdalsrsinfo("-o", "wkt2", @projection).gsub(/\n\n+|\A\n+/, "")
      else
        area_km2 = @neatline.area * (0.000001 * @scale)**2
        extents_km = @dimensions.times(0.000001 * @scale)
        StringIO.new.tap do |io|
          io.puts "%-11s 1:%i" %            ["scale:",      @scale]
          io.puts "%-11s %imm × %imm" %     ["dimensions:", *@dimensions.map(&:round)]
          io.puts "%-11s %.1fkm × %.1fkm" % ["extent:",     *extents_km]
          io.puts "%-11s %.1fkm²" %         ["area:",       area_km2]
          io.puts "%-11s %.1f°" %           ["rotation:",   @rotation]
          layers.reject(&empty ? :nil? : :empty?).inject("layers:") do |heading, layer|
            io.puts "%-11s %s" % [heading, layer]
            nil
          end
        end.string
      end
    end
    alias to_s info

    def render(*paths, worldfile: false, force: false, background: nil, **options)
      @archive.delete "map.svg" if force
      Dir.mktmppath do |temp_dir|
        rasters = Hash.new do |rasters, opts|
          png_path = temp_dir / "raster.#{rasters.size}.png"
          pgw_path = temp_dir / "raster.#{rasters.size}.pgw"
          rasterise png_path, background: background, **opts
          write_world_file pgw_path, **opts
          rasters[opts] = png_path
        end
        dithers = Hash.new do |dithers, opts|
          png_path = temp_dir / "dither.#{dithers.size}.png"
          pgw_path = temp_dir / "dither.#{dithers.size}.pgw"
          FileUtils.cp rasters[opts], png_path
          dither png_path
          write_world_file pgw_path, **opts
          dithers[opts] = png_path
        end

        outputs = paths.map.with_index do |path, index|
          ext = path.extname.delete_prefix ?.
          name = path.basename(path.extname)
          out_path = temp_dir / "output.#{index}.#{ext}"
          send "render_#{ext}", out_path, name: name, background: background, **options do |dither: false, **opts|
            (dither ? dithers : rasters)[opts]
          end
          next out_path, path
        end

        safely "saving, please wait..." do
          outputs.each do |out_path, path|
            FileUtils.cp out_path, path
            log_success "created %s" % path
          rescue SystemCallError
            raise "couldn't save #{path}"
          end

          paths.select do |path|
            %w[.png .tif .jpg].include? path.extname
          end.group_by do |path|
            path.parent / path.basename(path.extname)
          end.keys.each do |base|
            write_world_file Pathname("#{base}.wld"), ppi: options.fetch(:ppi, Formats::PPI)
            Pathname("#{base}.prj").write "#{@projection}\n"
          end if worldfile
        end
      end
    end
  end
end

module NSWTopo
  class Map
    include Formats, Dither, Zip, Log, Safely

    def initialize(archive, proj4:, scale:, centre:, extents:, rotation:, layers: {})
      @archive, @scale, @centre, @extents, @rotation, @layers = archive, scale, centre, extents, rotation, layers
      @projection = Projection.new proj4
      ox, oy = bounding_box.coordinates[0][3]
      @affine = [[1, 0], [0, -1], [-ox, oy]].map do |vector|
        vector.rotate_by_degrees(-@rotation).times(1000.0 / @scale)
      end.transpose
    end
    attr_reader :projection, :scale, :centre, :extents, :rotation

    extend Forwardable
    delegate %i[write mtime read] => :@archive

    def self.init(archive, scale: 25000, rotation: 0.0, bounds: nil, coords: nil, dimensions: nil, margins: nil)
      wgs84_points = case
      when coords && bounds
        raise "can't specify both bounds file and map coordinates"
      when coords
        coords
      when bounds
        gps = GPS.load bounds
        margins ||= [15, 15] unless dimensions || gps.polygons.any?
        case
        when gps.polygons.any?
          gps.polygons.map(&:coordinates).flatten(1).inject(&:+)
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

      wgs84_centre = wgs84_points.transpose.map(&:minmax).map(&:sum).times(0.5)
      projection = Projection.azimuthal_equidistant *wgs84_centre

      case rotation
      when "auto"
        raise "can't specify both map dimensions and auto-rotation" if dimensions
        points = GeoJSON.multipoint(wgs84_points).reproject_to(projection).coordinates
        centre, extents, rotation = points.minimum_bounding_box(*margins)
        rotation *= -180.0 / Math::PI
      when "magnetic"
        rotation = declination(*wgs84_centre)
      else
        raise "map rotation must be between ±45°" unless rotation.abs <= 45
      end

      case
      when centre
      when dimensions
        raise "can't specify both margins and map dimensions" if margins
        extents = dimensions.map do |dimension|
          dimension * 0.001 * scale
        end
        centre = GeoJSON.point(wgs84_centre).reproject_to(projection).coordinates
      else
        points = GeoJSON.multipoint(wgs84_points).reproject_to(projection).coordinates
        centre, extents = points.map do |point|
          point.rotate_by_degrees rotation
        end.transpose.map(&:minmax).map do |min, max|
          [0.5 * (max + min), max - min]
        end.transpose
        centre.rotate_by_degrees! -rotation
      end

      wgs84_centre = GeoJSON.point(centre, projection: projection).reproject_to_wgs84.coordinates
      projection = Projection.transverse_mercator *wgs84_centre

      extents = extents.zip(margins).map do |extent, margin|
        extent + 2 * margin * 0.001 * scale
      end if margins

      case
      when extents.all?(&:positive?)
      when coords
        raise "not enough information to calculate map size – add more coordinates, or specify map dimensions or margins"
      when bounds
        raise "not enough information to calculate map size – check bounds file, or specify map dimensions or margins"
      end

      new(archive, proj4: projection.proj4, scale: scale, centre: [0, 0], extents: extents, rotation: rotation).save
    end

    def self.load(archive)
      new archive, **YAML.load(archive.read "map.yml")
    end

    def save
      tap { @archive.write "map.yml", YAML.dump(proj4: @projection.proj4, scale: @scale, centre: @centre, extents: @extents, rotation: @rotation, layers: @layers) }
    end

    def layers
      @layers.map do |name, params|
        Layer.new(name, self, params)
      end
    end

    def raster_dimensions_at(ppi: nil, resolution: nil)
      resolution ||= 0.0254 * @scale / ppi
      ppi ||= 0.0254 * @scale / resolution
      return (@extents / resolution).map(&:ceil), ppi, resolution
    end

    def wgs84_centre
      GeoJSON.point(@centre, projection: @projection).reproject_to_wgs84.coordinates
    end

    def bounding_box(mm: nil, metres: nil)
      margin = mm ? mm * 0.001 * @scale : metres ? metres : 0
      ring = @extents.map do |extent|
        [-0.5 * extent - margin, 0.5 * extent + margin]
      end.inject(&:product).map do |offset|
        @centre.plus offset.rotate_by_degrees(-@rotation)
      end.values_at(0,2,3,1,0)
      GeoJSON.polygon [ring], projection: projection
    end

    def bounds(margin: {}, projection: nil)
      bounding_box(margin).yield_self do |bbox|
        projection ? bbox.reproject_to(projection) : bbox
      end.coordinates.first.transpose.map(&:minmax)
    end

    def projwin(projection)
      bounds(projection: projection).flatten.values_at(0,3,1,2)
    end

    def write_world_file(path, resolution: nil, ppi: nil)
      resolution ||= 0.0254 * @scale / ppi
      top_left = bounding_box.coordinates[0][3]
      WorldFile.write top_left, resolution, -@rotation, path
    end

    def coords_to_mm(point)
      @affine.map do |row|
        row.dot [*point, 1.0]
      end
    end

    def get_raster_resolution(raster_path)
      metre_diagonal = bounding_box.coordinates.first.values_at(0, 2)
      pixel_diagonal = OS.gdaltransform "-i", "-t_srs", @projection, raster_path do |stdin|
        metre_diagonal.each do |point|
          stdin.puts point.join(?\s)
        end
      end.each_line.map do |line|
        line.split(?\s).take(2).map(&:to_f)
      end
      metre_diagonal.distance / pixel_diagonal.distance
    rescue OS::Error
      raise "invalid raster"
    end

    def self.declination(longitude, latitude)
      today = Date.today
      query = { lat1: latitude.abs, lat1Hemisphere: latitude < 0 ? ?S : ?N, lon1: longitude.abs, lon1Hemisphere: longitude < 0 ? ?W : ?E, model: "WMM", startYear: today.year, startMonth: today.month, startDay: today.day, resultFormat: "xml" }
      uri = URI::HTTPS.build host: "www.ngdc.noaa.gov", path: "/geomag-web/calculators/calculateDeclination", query: URI.encode_www_form(query)
      xml = Net::HTTP.get uri
      text = REXML::Document.new(xml).elements["//declination"]&.text
      text ? text.to_f : raise
    rescue RuntimeError, SystemCallError, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError
      raise "couldn't get magnetic declination value"
    end

    def declination
      Map.declination *wgs84_centre
    end

    def add(*layers, after: nil, before: nil, replace: nil, overwrite: false)
      [%w[before after replace], [before, after, replace]].transpose.select(&:last).each do |option, name|
        next if self.layers.any? { |other| other.name == name }
        raise "no such layer: %s" % name
      end.map(&:first).combination(2).each do |options|
        raise OptionParser::AmbiguousOption,  "can't specify --%s and --%s simultaneously" % options
      end

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
      rescue ArcGISServer::Error, RuntimeError => error
        log_warn ArcGISServer::Error === error ? "couldn't download layer: #{layer.name}" : error.message
        next layers, changed, follow, errors << error
      end.tap do |ordered_layers, changed, follow, errors|
        if changed
          @layers.replace Hash[ordered_layers.map(&:pair)]
          replace ? delete(replace) : save
        end
        raise PartialFailureError, "failed to create %s" % [layers.one? ? "layer" : errors.one? ? "1 layer" : "#{errors.length} layers"] if errors.any?
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

    def info(empty: nil)
      StringIO.new.tap do |io|
        io.puts "%-11s 1:%i" %            ["scale:",      @scale]
        io.puts "%-11s %imm × %imm" %     ["dimensions:", *@extents.times(1000.0 / @scale)]
        io.puts "%-11s %.1fkm × %.1fkm" % ["extent:",     *@extents.times(0.001)]
        io.puts "%-11s %.1fkm²" %         ["area:",       @extents.inject(&:*) * 0.000001]
        io.puts "%-11s %.1f°" %           ["rotation:",   @rotation]
        layers.reject(&empty ? :nil? : :empty?).inject("layers:") do |heading, layer|
          io.puts "%-11s %s" % [heading, layer]
          nil
        end
      end.string
    end
    alias to_s info

    def render(*paths, worldfile: false, force: false, external: nil, **options)
      @archive.delete "map.svg" if force
      Dir.mktmppath do |temp_dir|
        rasters = Hash.new do |rasters, opts|
          png_path = temp_dir / "raster.#{rasters.size}.png"
          pgw_path = temp_dir / "raster.#{rasters.size}.pgw"
          rasterise png_path, external: external, **opts
          write_world_file pgw_path, opts
          rasters[opts] = png_path
        end
        dithers = Hash.new do |dithers, opts|
          png_path = temp_dir / "dither.#{dithers.size}.png"
          pgw_path = temp_dir / "dither.#{dithers.size}.pgw"
          FileUtils.cp rasters[opts], png_path
          dither png_path
          write_world_file pgw_path, opts
          dithers[opts] = png_path
        end

        outputs = paths.map.with_index do |path, index|
          ext = path.extname.delete_prefix ?.
          name = path.basename(path.extname)
          out_path = temp_dir / "output.#{index}.#{ext}"
          send "render_#{ext}", out_path, name: name, external: external, **options do |dither: false, **opts|
            (dither ? dithers : rasters)[opts]
          end
          next out_path, path
        end

        safely "saving, please wait..." do
          outputs.each do |out_path, path|
            FileUtils.cp out_path, path
            log_success "created %s" % path
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

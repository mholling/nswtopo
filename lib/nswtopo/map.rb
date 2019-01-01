module NSWTopo
  class Map
    include Formats

    def initialize(archive, config, centre = nil)
      @archive, @config, @centre = archive, config, centre
      @centre ||= GeoJSON::Collection.load(read "map.json")
      @properties = OpenStruct.new(@centre.properties)
    end

    extend Forwardable
    delegate [ :to_json, :projection, :coordinates ] => :@centre
    delegate [ :scale, :extents, :rotation ] => :@properties
    delegate [ :write, :mtime, :delete, :read, :uptodate? ] => :@archive

    def self.init(archive, config, options)
      wgs84_points = case
      when options[:coords] && options[:bounds]
        raise "can't specify both bounds file and map coordinates"
      when options[:coords]
        options[:coords]
      when options[:bounds]
        gps = GPS.load options[:bounds]
        options[:margins] ||= [ 15, 15 ] unless options[:dimensions] || gps.polygons.any?
        case
        when gps.polygons.any?
          gps.polygons.map(&:coordinates).flatten(1).inject(&:+)
        when gps.linestrings.any?
          gps.linestrings.map(&:coordinates).inject(&:+)
        when gps.points.any?
          gps.points.map(&:coordinates)
        else
          raise "no features found in %s" % options[:bounds]
        end
      else
        raise "no bounds file or map coordinates specified"
      end

      wgs84_centre = wgs84_points.transpose.map(&:minmax).map(&:sum).times(0.5)
      projection = Projection.transverse_mercator(wgs84_centre.first, 1.0)

      case options[:rotation]
      when "auto"
        raise "can't specify both map dimensions and auto-rotation" if options[:dimensions]
        coords = GeoJSON.multipoint(wgs84_points).reproject_to(projection).coordinates
        centre, extents, rotation = coords.minimum_bounding_box
        rotation *= 180.0 / Math::PI
      when "magnetic"
        rotation = -declination(*wgs84_centre)
      else
        rotation = -options[:rotation]
        raise "map rotation must be between ±45°" unless rotation.abs <= 45
      end

      case
      when centre
      when options[:dimensions]
        raise "can't specify both margins and map dimensions" if options[:margins]
        extents = options[:dimensions].map do |dimension|
          dimension * 0.001 * options[:scale]
        end
        centre = GeoJSON.point(wgs84_centre).reproject_to(projection).coordinates
      else
        coords = GeoJSON.multipoint(wgs84_points).reproject_to(projection).coordinates
        centre, extents = coords.map do |point|
          point.rotate_by_degrees(-rotation)
        end.transpose.map(&:minmax).map do |min, max|
          [ 0.5 * (max + min), max - min ]
        end.transpose
        centre.rotate_by_degrees!(rotation)
      end

      extents = extents.zip(options[:margins]).map do |extent, margin|
        extent + 2 * margin * 0.001 * options[:scale]
      end if options[:margins]

      case
      when extents.all?(&:positive?)
      when options[:coords]
        raise "not enough information to calculate map size – add more coordinates, or specify map dimensions or margins"
      when options[:bounds]
        raise "not enough information to calculate map size – check bounds file, or specify map dimensions or margins"
      end

      new archive, config, GeoJSON.point(centre, projection, "scale" => options[:scale], "extents" => extents, "rotation" => rotation, "layers" => {})
    rescue GPS::BadFile => error
      raise "invalid bounds file #{error.message}"
    end

    def save
      tap { write "map.json", to_json }
    end

    def layers
      @properties.layers.map do |name, params|
        Layer.new(name, self, params)
      end
    end

    def add(*layers, after: nil, before: nil, overwrite: false)
      layers.inject [ self.layers, after, [] ] do |(layers, follow, errors), layer|
        index = layers.index layer unless after || before
        layers.delete layer
        case
        when index
        when follow
          index = layers.index { |other| other.name == follow }
          raise "no such layer: #{follow}" unless index
          index += 1
        when before
          index = layers.index { |other| other.name == before }
          raise "no such layer: #{before}" unless index
        else
          index = layers.index { |other| (other <=> layer) > 0 } || -1
        end
        if overwrite || !layer.uptodate?
          layer.create
        else
          puts "#{layer.name}: keeping pre-existing layer"
        end
        next layers.insert(index, layer), layer.name, errors
      rescue ArcGISServer::Error => error
        warn "#{layer.name}: couldn't download layer"
        next layers, follow, errors << error
      end.tap do |layers, follow, errors|
        @properties.layers.replace Hash[layers.map(&:pair)]
        raise PartialFailureError, "download failed for #{errors.length} layer#{?s unless errors.one?}" if errors.any?
      end
    end

    def remove(*names)
      names.inject Set[] do |matched, name|
        matches = @properties.layers.keys.grep(name)
        raise "no such layer: #{name}" if String === name && matches.none?
        matched.merge matches
      end.each do |name|
        params = @properties.layers.delete name
        delete Layer.new(name, self, params).filename
      end.any?
    end

    def info(empty: nil)
      StringIO.new.tap do |io|
        io.puts "%-9s 1:%i" %            [ "scale:",    scale ]
        io.puts "%-9s %imm × %imm" %     [ "size:",     *extents.times(1000.0 / scale) ]
        io.puts "%-9s %.1fkm × %.1fkm" % [ "extent:",   *extents.times(0.001) ]
        io.puts "%-9s %.1fkm²" %         [ "area:",     extents.inject(&:*) * 0.000001 ]
        io.puts "%-9s %.1f°" %           [ "rotation:", 0.0 - rotation ]
        layers.reject(&empty ? :nil? : :empty?).inject("layers:") do |heading, layer|
          io.puts "%-9s %s" % [ heading, layer ]
          nil
        end
      end.string
    end
    alias to_s info

    def svg
      return REXML::Document.new(xml) if xml = read("map.svg")
      raise "TODO: code here to build svg from scratch (saving before returning)"
    end

    def render(*paths, **options)
      paths.each do |path|
        ext = path.extname.delete_prefix ?.
        send "render_#{ext}", path, **options
      end
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
      Map.declination *@centre.reproject_to_wgs84.coordinates
    end

    def bounding_box(mm: nil, metres: nil)
      margin = mm ? mm * 0.01 * scale : metres ? metres : 0
      ring = extents.map do |extent|
        [ -0.5 * extent - margin, 0.5 * extent + margin ]
      end.inject(&:product).map do |offset|
        coordinates.plus offset.rotate_by_degrees(rotation)
      end.values_at(0,2,3,1,0)
      GeoJSON.polygon [ ring ], projection
    end

    def bounds(margin: {}, projection: nil)
      bounding_box(margin).yield_self do |bbox|
        projection ? bbox.reproject_to(projection) : bbox
      end.coordinates.first.transpose.map(&:minmax)
    end

    def projwin(projection)
      bounds(projection: projection).flatten.values_at(0,3,1,2)
    end

    def write_world_file(path, resolution)
      top_left = bounding_box.coordinates[0][3]
      WorldFile.write top_left, resolution, rotation, path
    end


    # def xml
    #   millimetres = @extents.map { |extent| 1000.0 * extent / @scale }
    #   REXML::Document.new.tap do |xml|
    #     xml << REXML::XMLDecl.new(1.0, "utf-8")
    #     attributes = {
    #       "version" => 1.1,
    #       "baseProfile" => "full",
    #       "xmlns" => "http://www.w3.org/2000/svg",
    #       "xmlns:xlink" => "http://www.w3.org/1999/xlink",
    #       "xmlns:ev" => "http://www.w3.org/2001/xml-events",
    #       "xmlns:sodipodi" => "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd",
    #       "xmlns:inkscape" => "http://www.inkscape.org/namespaces/inkscape",
    #       "width"  => "#{millimetres[0]}mm",
    #       "height" => "#{millimetres[1]}mm",
    #       "viewBox" => "0 0 #{millimetres[0]} #{millimetres[1]}",
    #     }
    #     xml.add_element("svg", attributes).tap do |svg|
    #       svg.add_element("sodipodi:namedview", "borderlayer" => true)
    #       svg.add_element("defs")
    #       svg.add_element("rect", "x" => 0, "y" => 0, "width" => millimetres[0], "height" => millimetres[1], "fill" => "white")
    #     end
    #   end
    # end
  end
end
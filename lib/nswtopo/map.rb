module NSWTopo
  class Map
    attr_reader :debug
    
    def initialize(config)
      @name, @scale, @debug = config.values_at("name", "scale", "debug")
      
      wgs84_points = case
      when config["zone"] && config["eastings"] && config["northings"]
        utm = Projection.utm(config["zone"])
        utm.reproject_to_wgs84 config.values_at("eastings", "northings").inject(:product)
      when config["longitudes"] && config["latitudes"]
        config.values_at("longitudes", "latitudes").inject(:product)
      when config["size"] && config["zone"] && config["easting"] && config["northing"]
        utm = Projection.utm(config["zone"])
        [ utm.reproject_to_wgs84(config.values_at("easting", "northing")) ]
      when config["size"] && config["longitude"] && config["latitude"]
        [ config.values_at("longitude", "latitude") ]
      when config["bounds"]
        bounds_path = Pathname.new(config["bounds"]).expand_path
        gps = GPS.new bounds_path
        polygon = gps.areas.first
        config["margin"] = 15 unless (gps.waypoints.none? && gps.tracks.none?) || config.key?("margin")
        polygon ? polygon.first : gps.tracks.any? ? gps.tracks.to_a.transpose.first.inject(&:+) : gps.waypoints.to_a.transpose.first
      else
        abort "Error: map extent must be provided as a bounds file, zone/eastings/northings, zone/easting/northing/size, latitudes/longitudes or latitude/longitude/size"
      end
      
      @projection_centre = wgs84_points.transpose.map { |coords| 0.5 * (coords.max + coords.min) }
      @projection = config["utm"] ?
        Projection.utm(config["zone"] || Projection.utm_zone(@projection_centre, Projection.wgs84)) :
        Projection.transverse_mercator(@projection_centre.first, 1.0)
      
      @declination = config["declination"]["angle"] if config["declination"]
      config["rotation"] = -declination if config["rotation"] == "magnetic"
      
      if config["size"]
        sizes = config["size"].split(/[x,]/).map(&:to_f)
        abort "Error: invalid map size: #{config["size"]}" unless sizes.length == 2 && sizes.all? { |size| size > 0.0 }
        @extents = sizes.map { |size| size * 0.001 * scale }
        @rotation = config["rotation"]
        abort "Error: cannot specify map size and auto-rotation together" if @rotation == "auto"
        abort "Error: map rotation must be between +/-45 degrees" unless @rotation.abs <= 45
        @centre = reproject_from_wgs84 @projection_centre
      else
        puts "Calculating map bounds..."
        bounding_points = reproject_from_wgs84 wgs84_points
        if config["rotation"] == "auto"
          @centre, @extents, @rotation = bounding_points.minimum_bounding_box
          @rotation *= 180.0 / Math::PI
        else
          @rotation = config["rotation"]
          abort "Error: map rotation must be between -45 and +45 degrees" unless rotation.abs <= 45
          @centre, @extents = bounding_points.map do |point|
            point.rotate_by_degrees(-rotation)
          end.transpose.map do |coords|
            [ coords.max, coords.min ]
          end.map do |max, min|
            [ 0.5 * (max + min), max - min ]
          end.transpose
          @centre.rotate_by_degrees!(rotation)
        end
        margins = [ *config["margin"], *config["margin"] ].take(2)
        @extents = @extents.zip(margins).map do |extent, margin|
          extent + 2 * margin * 0.001 * @scale
        end if margins.any?
      end

      enlarged_extents = [ @extents[0] * Math::cos(@rotation * Math::PI / 180.0) + @extents[1] * Math::sin(@rotation * Math::PI / 180.0).abs, @extents[0] * Math::sin(@rotation * Math::PI / 180.0).abs + @extents[1] * Math::cos(@rotation * Math::PI / 180.0) ]
      @bounds = [ @centre, enlarged_extents ].transpose.map { |coord, extent| [ coord - 0.5 * extent, coord + 0.5 * extent ] }
    rescue BadGpxKmlFile => e
      abort "Error: invalid bounds file #{e.message}"
    end
    
    attr_reader :name, :scale, :projection, :bounds, :centre, :extents, :rotation
    
    def reproject_from(projection, point_or_points)
      projection.reproject_to(@projection, point_or_points)
    end
    
    def reproject_from_wgs84(point_or_points)
      reproject_from(Projection.wgs84, point_or_points)
    end
    
    def transform_bounds_to(target_projection)
      @projection.transform_bounds_to target_projection, bounds
    end
    
    def wgs84_bounds
      transform_bounds_to Projection.wgs84
    end
    
    def resolution_at(ppi)
      @scale * 0.0254 / ppi
    end
    
    def dimensions_at(ppi)
      @extents.map { |extent| (ppi * extent / @scale / 0.0254).floor }
    end
    
    def top_left
      [ @centre, @extents.rotate_by_degrees(-@rotation), [ :-, :+ ] ].transpose.map { |coord, extent, plus_minus| coord.send(plus_minus, 0.5 * extent) }
    end
    
    def geotransform_at(ppi)
      WorldFile.geotransform top_left, resolution_at(ppi), @rotation
    end
    
    def coord_corners(margin_in_mm = 0)
      metres = margin_in_mm * 0.001 * @scale
      @extents.map do |extent|
        [ -0.5 * extent - metres, 0.5 * extent + metres ]
      end.inject(&:product).values_at(0,2,3,1).map do |point|
        @centre.plus point.rotate_by_degrees(@rotation)
      end
    end
    
    def wgs84_corners
      @projection.reproject_to_wgs84 coord_corners
    end
    
    def coords_to_mm(coords)
      coords.one_or_many do |easting, northing|
        [ easting - bounds.first.first, bounds.last.last - northing ].map do |metres|
          1000.0 * metres / scale
        end
      end
    end
    
    def mm_corners(*args)
      coords_to_mm coord_corners(*args).reverse
    end
    
    def overlaps?(bounds)
      axes = [ [ 1, 0 ], [ 0, 1 ] ].map { |axis| axis.rotate_by_degrees(@rotation) }
      bounds.inject(&:product).map do |corner|
        axes.map { |axis| corner.minus(@centre).dot(axis) }
      end.transpose.zip(@extents).none? do |projections, extent|
        projections.max < -0.5 * extent || projections.min > 0.5 * extent
      end
    end
    
    def write_world_file(path, resolution)
      WorldFile.write top_left, resolution, @rotation, path
    end
    
    def write_oziexplorer_map(path, name, image, ppi)
      dimensions = dimensions_at(ppi)
      pixel_corners = dimensions.each.with_index.map { |dimension, order| [ 0, dimension ].rotate(order) }.inject(:product).values_at(0,2,3,1)
      calibration_strings = [ pixel_corners, wgs84_corners ].transpose.map.with_index do |(pixel_corner, wgs84_corner), index|
        dmh = [ wgs84_corner, [ [ ?E, ?W ], [ ?N, ?S ] ] ].transpose.reverse.map do |coord, hemispheres|
          [ coord.abs.floor, 60 * (coord.abs - coord.abs.floor), coord > 0 ? hemispheres.first : hemispheres.last ]
        end
        "Point%02i,xy,%i,%i,in,deg,%i,%f,%c,%i,%f,%c,grid,,,," % [ index+1, pixel_corner, dmh ].flatten
      end
      path.open("w") do |file|
        file << %Q[OziExplorer Map Data File Version 2.2
#{name}
#{image}
1 ,Map Code,
WGS 84,WGS84,0.0000,0.0000,WGS84
Reserved 1
Reserved 2
Magnetic Variation,,,E
Map Projection,Transverse Mercator,PolyCal,No,AutoCalOnly,Yes,BSBUseWPX,No
#{calibration_strings.join ?\n}
Projection Setup,0.000000000,#{projection.central_meridian},#{projection.scale_factor},500000.00,10000000.00,,,,,
Map Feature = MF ; Map Comment = MC     These follow if they exist
Track File = TF      These follow if they exist
Moving Map Parameters = MM?    These follow if they exist
MM0,Yes
MMPNUM,4
#{pixel_corners.reverse.map.with_index { |pixel_corner, index| "MMPXY,#{index+1},#{pixel_corner.join ?,}" }.join ?\n}
#{wgs84_corners.reverse.map.with_index { |wgs84_corner, index| "MMPLL,#{index+1},#{wgs84_corner.join ?,}" }.join ?\n}
MM1B,#{resolution_at ppi}
MOP,Map Open Position,0,0
IWH,Map Image Width/Height,#{dimensions.join ?,}
].gsub(/\r\n|\r|\n/, "\r\n")
      end
    end
    
    def declination
      @declination ||= begin
        today = Date.today
        easting, northing = @projection_centre
        query = { "lat1" => northing.abs, "lat1Hemisphere" => northing < 0 ? ?S : ?N, "lon1" => easting.abs, "lon1Hemisphere" => easting < 0 ?W : ?E, "model" => "WMM", "startYear" => today.year, "startMonth" => today.month, "startDay" => today.day, "resultFormat" => "xml" }
        uri = URI::HTTPS.build :host => "www.ngdc.noaa.gov", :path => "/geomag-web/calculators/calculateDeclination"
        HTTP.post(uri, query.to_query) do |response|
          begin
            REXML::Document.new(response.body).elements["//declination"].text.to_f
          rescue REXML::ParseException
            raise ServerError.new("couldn't get magnetic declination value")
          end
        end
      end
    end
    
    def xml
      millimetres = @extents.map { |extent| 1000.0 * extent / @scale }
      REXML::Document.new.tap do |xml|
        xml << REXML::XMLDecl.new(1.0, "utf-8")
        attributes = {
          "version" => 1.1,
          "baseProfile" => "full",
          "xmlns" => "http://www.w3.org/2000/svg",
          "xmlns:xlink" => "http://www.w3.org/1999/xlink",
          "xmlns:ev" => "http://www.w3.org/2001/xml-events",
          "xmlns:sodipodi" => "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd",
          "xmlns:inkscape" => "http://www.inkscape.org/namespaces/inkscape",
          "width"  => "#{millimetres[0]}mm",
          "height" => "#{millimetres[1]}mm",
          "viewBox" => "0 0 #{millimetres[0]} #{millimetres[1]}",
        }
        xml.add_element("svg", attributes).tap do |svg|
          svg.add_element("sodipodi:namedview", "borderlayer" => true)
          svg.add_element("defs")
          svg.add_element("rect", "x" => 0, "y" => 0, "width" => millimetres[0], "height" => millimetres[1], "fill" => "white")
        end
      end
    end
  end
end
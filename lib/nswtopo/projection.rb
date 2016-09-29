module NSWTopo
  class Projection
    def initialize(string)
      @string = string
    end
    
    %w[proj4 wkt wkt_simple wkt_noct wkt_esri mapinfo xml].map do |format|
      [ format, "@#{format}" ]
    end.map do |format, variable|
      define_method format do
        instance_variable_get(variable) || begin
          instance_variable_set variable, %x[gdalsrsinfo -o #{format} "#{@string}"].split(/['\r\n]+/).map(&:strip).join("")
        end
      end
    end
    
    alias_method :to_s, :proj4
    
    %w[central_meridian scale_factor].each do |parameter|
      define_method parameter do
        /PARAMETER\["#{parameter}",([\d\.]+)\]/.match(wkt) { |match| match[1].to_f }
      end
    end
    
    def self.utm(zone, south = true)
      new("+proj=utm +zone=#{zone}#{' +south' if south} +ellps=WGS84 +datum=WGS84 +units=m +no_defs")
    end
    
    def self.wgs84
      new("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")
    end
    
    def self.transverse_mercator(central_meridian, scale_factor)
      new("+proj=tmerc +lat_0=0.0 +lon_0=#{central_meridian} +k=#{scale_factor} +x_0=500000.0 +y_0=10000000.0 +ellps=WGS84 +datum=WGS84 +units=m")
    end
    
    def reproject_to(target, point_or_points)
      gdaltransform = %Q[gdaltransform -s_srs "#{self}" -t_srs "#{target}"]
      case point_or_points.first
      when Array
        point_or_points.map do |point|
          "echo #{point.join ?\s}"
        end.inject([]) do |(*echoes, last), echo|
          case
          when last && last.length + echo.length + gdaltransform.length < 2000 then [ *echoes, "#{last} && #{echo}" ]
          else [ *echoes, *last, echo ]
          end
        end.map do |echoes|
          %x[(#{echoes}) | #{gdaltransform}].each_line.map do |line|
            line.split(?\s)[0..1].map(&:to_f)
          end
        end.inject(&:+)
      else %x[echo #{point_or_points.join ?\s} | #{gdaltransform}].split(?\s)[0..1].map(&:to_f)
      end
    end
    
    def reproject_to_wgs84(point_or_points)
      reproject_to Projection.wgs84, point_or_points
    end
    
    def transform_bounds_to(target, bounds)
      reproject_to(target, bounds.inject(&:product)).transpose.map { |coords| [ coords.min, coords.max ] }
    end
    
    def self.utm_zone(coords, projection)
      projection.reproject_to_wgs84(coords).one_or_many do |longitude, latitude|
        (longitude / 6).floor + 31
      end
    end
    
    def self.in_zone?(zone, coords, projection)
      projection.reproject_to_wgs84(coords).one_or_many do |longitude, latitude|
        (longitude / 6).floor + 31 == zone
      end
    end
    
    def self.utm_hull(zone)
      longitudes = [ 31, 30 ].map { |offset| (zone - offset) * 6.0 }
      latitudes = [ -80.0, 84.0 ]
      longitudes.product(latitudes).values_at(0,2,3,1)
    end
  end
end

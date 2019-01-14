module NSWTopo
  module WorldFile
    extend self

    def geotransform(top_left, resolution, angle)
      sin, cos = Math::sin(angle * Math::PI / 180.0), Math::cos(angle * Math::PI / 180.0)
      [[top_left[0], resolution * cos,  resolution * sin],
       [top_left[1], resolution * sin, -resolution * cos]]
    end

    def write(top_left, resolution, angle, path)
      (x, r00, r01), (y, r10, r11) = geotransform(top_left, resolution, angle)
      path.open("w") do |file|
        file.puts r00, r01, r10, r11
        file.puts x + 0.5 * resolution, y - 0.5 * resolution
      end
    end
  end
end

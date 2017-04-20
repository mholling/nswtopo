module NSWTopo
  module WorldFile
    def self.affine_transform(top_left, resolution, angle)
      sin, cos = Math::sin(angle * Math::PI / 180.0), Math::cos(angle * Math::PI / 180.0)
      [ [ resolution * cos,  resolution * sin, top_left[0] ],
        [ resolution * sin, -resolution * cos, top_left[1] ] ]
    end
    
    def self.write(top_left, resolution, angle, path)
      (r00, r01, x), (r10, r11, y) = affine_transform(top_left, resolution, angle)
      path.open("w") do |file|
        file.puts r00, r01, r10, r11
        file.puts x + 0.5 * resolution, y - 0.5 * resolution
      end
    end
  end
end
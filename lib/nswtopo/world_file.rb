module NSWTopo
  module WorldFile
    def self.write(topleft, resolution, angle, path)
      path.open("w") do |file|
        file.puts  resolution * Math::cos(angle * Math::PI / 180.0)
        file.puts  resolution * Math::sin(angle * Math::PI / 180.0)
        file.puts  resolution * Math::sin(angle * Math::PI / 180.0)
        file.puts -resolution * Math::cos(angle * Math::PI / 180.0)
        file.puts topleft.first + 0.5 * resolution
        file.puts topleft.last - 0.5 * resolution
      end
    end
  end
end
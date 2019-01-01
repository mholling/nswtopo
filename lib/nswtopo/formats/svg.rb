module NSWTopo::Formats
  module Svg
    def render_svg(path, **options)
      if uptodate? "map.svg"
        path.write read("map.svg")
        return
      end
      svg = "stub"
      write "map.svg", svg
      path.write svg
    end
  end
end

# svg_path.open("w") do |file|
#   formatter = REXML::Formatters::Pretty.new
#   formatter.compact = true
#   formatter.write svg, file
# end

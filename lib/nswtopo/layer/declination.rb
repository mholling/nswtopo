module NSWTopo
  module Declination
    include Vector
    CREATE = %w[angle spacing arrows offset]

    def features
      declination = @angle || @map.declination
      col_spacing = 0.001 * @map.scale * @spacing
      row_spacing = 0.001 * @map.scale * @arrows * 0.5
      col_offset = 0.001 * @map.scale * (@offset % @spacing)

      radius = 0.5 * @map.bounds.transpose.distance
      j_max = (radius / col_spacing).ceil
      i_max = (radius / row_spacing).ceil

      collection = GeoJSON::Collection.new(@map.projection)
      (-j_max .. j_max).each do |j|
        x = j * col_spacing + col_offset
        coordinates = [ [ x, -radius ], [ x, radius ] ].map do |point|
          point.rotate_by_degrees(-declination).plus(@map.coordinates)
        end
        collection.add_linestring coordinates
        (-i_max .. i_max).reject(&j.even? ? :even? : :odd?).map do |i|
          [ x, i * row_spacing ].rotate_by_degrees(-declination).plus(@map.coordinates)
        end.each do |coordinates|
          collection.add_point coordinates, "rotation" => -declination
        end
      end
      collection
    end

  end
end

# PARAMS = %q[
#   stroke: darkred
#   stroke-width: 0.1
#   fill: darkred
#   symbol:
#     path:
#       d: M 0 0 L 0.4 2 L 0 1.3 L -0.4 2 Z
#       stroke: none
# ]
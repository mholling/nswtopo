module NSWTopo
  module Declination
    include VectorRender
    CREATE = %w[angle spacing arrows offset]
    DEFAULTS = YAML.load <<~YAML
      spacing: 40.0
      offset: 0.0
      arrows: 160.0
      stroke: darkred
      stroke-width: 0.1
      symbol:
        path:
          d: M 0 0 L 0.4 2 L 0 1.3 L -0.4 2 Z
          stroke: none
    YAML

    def get_features
      @params["fill"] ||= @params["stroke"]
      declination = @angle || @map.declination
      col_spacing = @spacing
      row_spacing = @arrows * 0.5
      col_offset = @offset % @spacing

      radius = 0.5 * @map.neatline.bounds.transpose.then do |bl, tr|
        Vector[*tr] - Vector[*bl]
      end.norm

      j_max = (radius / col_spacing).ceil
      i_max = (radius / row_spacing).ceil

      (-j_max..j_max).each.with_object(GeoJSON::Collection.new(projection: @map.neatline.projection)) do |j, collection|
        x = j * col_spacing + col_offset
        coordinates = [radius, -radius].map do |y|
          Vector[x, y].rotate_by_degrees(declination - @map.rotation) + Vector[*@map.dimensions] / 2
        end
        collection.add_linestring coordinates
        (-i_max..i_max).reject(&j.even? ? :even? : :odd?).map do |i|
          Vector[x, i * row_spacing].rotate_by_degrees(declination - @map.rotation) + Vector[*@map.dimensions] / 2
        end.each do |coordinates|
          collection.add_point coordinates, "rotation" => declination
        end
      end
    end

    def to_s
      lines = features.grep(GeoJSON::LineString)
      return @name if lines.none?
      angle = lines.map(&:coordinates).map do |p0, p1|
        p1 - p0
      end.max_by(&:norm).then do |delta|
        90 + 180 * Math::atan2(delta.y, delta.x) / Math::PI + @map.rotation
      end
      "%s: %i line%s at %.1f°%s" % [@name, lines.length, (?s unless lines.one?), angle.abs, angle > 0 ? ?E : angle < 0 ? ?W : nil]
    end

  end
end

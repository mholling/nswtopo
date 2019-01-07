module NSWTopo
  module Grid
    include Vector
    CREATE = %w[interval]
    DEFAULTS = YAML.load <<~YAML
      stroke: black
      stroke-width: 0.1
      boundary:
        stroke: gray
    YAML

    def grids
      Projection.utm_zones(@map.bounding_box).map do |zone|
        utm = Projection.utm(zone)
        eastings, northings = @map.bounds(projection: utm).map do |min, max|
          (min / @interval).floor .. (max / @interval).ceil
        end.map do |counts|
          counts.map { |count| count * @interval }
        end
        grid = eastings.map do |easting|
          [ easting ].product northings.reverse
        end
        easting_lines, northing_lines = [ grid, grid.transpose ].map do |lines|
          GeoJSON.multilinestring lines, utm
        end
        [ zone, easting_lines, northing_lines ]
      end
    end

    def get_features
      grids.map do |zone, eastings, northings|
        [ eastings, northings ].map do |lines|
          lines.reproject_to_wgs84
        end.each do |lines|
          lines.clip! Projection.utm_hull(zone)
        end.yield_self do |eastings, northings|
          boundary = GeoJSON.linestring northings.coordinates.map(&:first)
          [ eastings, northings, boundary ].map(&:first)
        end.zip %w[easting northing boundary]
      end.flatten(1).inject(GeoJSON::Collection.new) do |result, (feature, category)|
        feature.properties.store "categories", [ category ]
        result << feature
      end.explode
    end

    def to_s
      @name
    end
  end
end

# PARAMS = %q[
#   label-spacing: 5
#   label-inset: 1.5
#   label-offset: 2
#   stroke: black
#   stroke-width: 0.1
#   boundary:
#     stroke: gray
#   labels:
#     dupe: outline
#     outline:
#       stroke: white
#       fill: none
#       stroke-width: 10%
#       opacity: 0.65
#     font-family: Arial Narrow, sans-serif
#     font-size: 2.3
#     stroke: none
#     fill: black
#     orientation: uphill
# ]

# attr_reader :font_size, :grid_interval, :label_spacing, :label_offset, :label_inset

# @name, @params = name, YAML.load(PARAMS).deep_merge(params)
# @font_size = @params["labels"]["font-size"]
# @grid_interval, @label_spacing, @label_offset, @label_inset = @params.values_at "interval", "label-spacing", "label-offset", "label-inset"

# def label_grids(label_interval)
#   grids.map do |zone, utm, grid|
#     eastings, northings = [ grid, grid.transpose ].map.with_index do |lines, index|
#       lines.select do |line|
#         line[0][index] % label_interval == 0
#       end.map do |line|
#         offset_line = line.map(&:dup).each do |coords|
#           coords[index] += 0.001 * label_offset * CONFIG.map.scale
#         end
#         [ line[0][index], offset_line ]
#       end.to_h
#     end
#     [ zone, utm, eastings, northings ]
#   end
# end

# def labels
#   label_spacing ? periodic_labels : edge_labels
# end

# def label(coord, label_interval)
#   parts = [ [ "%d" % (coord / 100000), 80 ], [ "%02d" % ((coord / 1000) % 100), 100 ] ]
#   parts << [ "%03d" % (coord % 1000), 80 ] unless label_interval % 1000 == 0
#   text_path = REXML::Element.new("textPath")
#   parts.each.with_index do |(text, percent), index|
#     tspan = text_path.add_element "tspan", "font-size" => "#{percent}%"
#     tspan.add_attributes "dy" => (0.35 * font_size).round(MM_DECIMAL_DIGITS) if index.zero?
#     tspan.add_text text
#   end
#   length = parts.map do |text, percent|
#     [ Font.glyph_length(?\s, @params["labels"]), Font.glyph_length(text, @params["labels"].merge("font-size" => font_size * percent / 100.0)) ]
#   end.flatten.drop(1).inject(&:+)
#   text_path.add_attribute "textLength", length
#   [ length, text_path ]
# end

# def edge_labels
#   edge_inset = label_inset + font_size * 0.5 * Math::sin(CONFIG.map.rotation.abs * Math::PI / 180)
#   corners = CONFIG.map.coord_corners(-edge_inset)
#   label_grids(grid_interval).map do |zone, utm, *lines|
#     corners.zip(corners.perps).map.with_index do |(corner, perp), index|
#       outgoing = index < 2
#       lines[index % 2].map do |coord, line|
#         segment = CONFIG.map.reproject_from(utm, line).segments.find do |points|
#           points.one? { |point| point.minus(corner).dot(perp) < 0.0 }
#         end
#         segment[outgoing ? 1 : 0] = segment.along(corner.minus(segment[0]).dot(perp) / segment.difference.dot(perp)) if segment
#         [ coord, segment ]
#       end.select(&:last).select do |coord, segment|
#         corners.surrounds?(segment).any? && Projection.in_zone?(zone, segment[outgoing ? 1 : 0], CONFIG.map.projection)
#       end.map do |coord, segment|
#         length, text_path = label(coord, grid_interval)
#         segment_length = 1000.0 * segment.distance / CONFIG.map.scale
#         fraction = length / segment_length
#         fractions = outgoing ? [ 1.0 - fraction, 1.0 ] : [ 0.0, fraction ]
#         baseline = fractions.map { |fraction| segment.along fraction }
#         [ 1, [ baseline ], text_path, index % 2 == 0 ? "eastings" : "northings" ]
#       end
#     end
#   end.flatten(2)
# end

# def periodic_labels
#   label_interval = label_spacing * grid_interval
#   label_grids(label_interval).map do |zone, utm, eastings, northings|
#     [ eastings, northings ].map.with_index do |lines, index|
#       lines.map do |coord, line|
#         line.segments.select do |segment|
#           segment[0][1-index] % label_interval == 0
#         end.select do |segment|
#           Projection.in_zone?(zone, segment, utm).all?
#         end.map do |segment|
#           CONFIG.map.reproject_from utm, segment
#         end.map do |segment|
#           length, text_path = label(coord, label_interval)
#           segment_length = 1000.0 * segment.distance / CONFIG.map.scale
#           fraction = length / segment_length
#           baseline = [ segment.along(0.5 * (1 - fraction)), segment.along(0.5 * (1 + fraction)) ]
#           [ 1, [ baseline ], text_path, index.zero? ? "eastings" : "northings" ]
#         end
#       end
#     end
#   end.flatten(3)
# end

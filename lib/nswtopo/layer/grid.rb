module NSWTopo
  module Grid
    include Vector
    CREATE = %w[interval]
    INSET = 1.5
    DEFAULTS = YAML.load <<~YAML
      interval: 1000.0
      stroke: black
      stroke-width: 0.1
      boundary:
        stroke: gray
      labels:
        dupe: outline
        outline:
          stroke: white
          fill: none
          stroke-width: 10%
          opacity: 0.65
        font-family: Arial Narrow, sans-serif
        font-size: 2.3
        stroke: none
        fill: black
        orientation: uphill
    YAML

    def get_features
      Projection.utm_zones(@map.bounding_box).map do |zone|
        utm, utm_hull = Projection.utm(zone), Projection.utm_hull(zone)
        map_hull = @map.bounding_box(MARGIN).reproject_to_wgs84.coordinates.first

        eastings, northings = @map.bounds(projection: utm).map do |min, max|
          (min / @interval).floor..(max / @interval).ceil
        end.map do |counts|
          counts.map { |count| count * @interval }
        end

        grid = eastings.map do |easting|
          [easting].product northings.reverse
        end

        eastings, northings = [grid, grid.transpose].map.with_index do |lines, index|
          lines.inject GeoJSON::Collection.new(utm) do |collection, line|
            coord = line[0][index]
            label = [coord / 100000, (coord / 1000) % 100]
            label << coord % 1000 unless @interval % 1000 == 0
            collection.add_linestring line, "label" => label, "ends" => [0, 1], "category" => index.zero? ? "easting" : "northing"
          end.reproject_to_wgs84.clip!(utm_hull).clip!(map_hull).each do |linestring|
            linestring["ends"].delete 0 if linestring.coordinates[0][0] % 6 < 0.00001
            linestring["ends"].delete 1 if linestring.coordinates[-1][0] % 6 < 0.00001
          end
        end

        boundary_points = GeoJSON.multilinestring(grid.transpose, projection: utm).reproject_to_wgs84.clip!(utm_hull).coordinates.map(&:first)
        boundary = GeoJSON.linestring boundary_points, properties: { "category" => "boundary" }

        [eastings, northings, boundary]
      end.flatten.inject(&:merge)
    end

    def label_element(labels, label_params)
      font_size = label_params["font-size"]
      parts = labels.zip(%w[%d %02d %03d]).map do |part, format|
        format % part
      end.zip([80, 100, 80])

      text_path = REXML::Element.new("textPath")
      parts.each.with_index do |(text, percent), index|
        tspan = text_path.add_element "tspan", "font-size" => "#{percent}%"
        tspan.add_attributes "dy" => VALUE % (Labels::CENTRELINE_FRACTION * font_size) if index.zero?
        tspan.add_text text
      end

      text_length = parts.flat_map do |text, percent|
        [Font.glyph_length(?\s, label_params), Font.glyph_length(text, label_params.merge("font-size" => font_size * percent / 100.0))]
      end.drop(1).sum
      text_path.add_attribute "textLength", VALUE % text_length
      [text_length, text_path]
    end

    def labeling_features
      label_params = @params["labels"]
      font_size = label_params["font-size"]
      offset = 0.85 * font_size * @map.scale / 1000.0
      inset = INSET + font_size * 0.5 * Math::sin(@map.rotation.abs * Math::PI / 180)
      inset_hull = @map.bounding_box(mm: -inset).coordinates.first

      gridlines = features.select do |linestring|
        linestring["label"]
      end
      eastings = gridlines.select do |gridline|
        gridline["category"] == "easting"
      end

      flip_eastings = eastings.partition do |easting|
        Math::atan2(*easting.coordinates.values_at(0, -1).inject(&:minus)) * 180.0 / Math::PI > @map.rotation
      end.map(&:length).inject(&:>)
      eastings.each do |easting|
        easting.coordinates.reverse!
        easting["ends"].map! { |index| 1 - index }
      end if flip_eastings

      gridlines.map do |gridline|
        gridline.offset(offset, splits: false).clip(inset_hull)
      end.compact.flat_map do |gridline|
        label, ends = gridline.values_at "label", "ends"
        %i[itself reverse].values_at(*ends).map do |order|
          text_length, text_path = label_element(label, label_params)
          segment = gridline.coordinates.send(order).take(2)
          fraction = text_length * @map.scale / 1000.0 / segment.distance
          coordinates = [segment[0], segment.along(fraction)].send(order)
          GeoJSON::LineString.new coordinates, "label" => text_path
        end
      end
    end

    def to_s
      @name
    end
  end
end

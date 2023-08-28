module NSWTopo
  module Grid
    include VectorRender
    CREATE = %w[interval border]
    INSET = 1.5
    DEFAULTS = YAML.load <<~YAML
      interval: 1000.0
      stroke: black
      stroke-width: 0.1
      edge:
        fill: none
        preserve: true
      labels:
        font-family: Arial Narrow, sans-serif
        font-size: 2.3
        stroke: none
        fill: black
        orientation: uphill
    YAML

    def get_features
      Projection.utm_zones(@map.neatline).flat_map do |zone|
        utm, utm_geometry = Projection.utm(zone), Projection.utm_geometry(zone)
        map_geometry = @map.neatline(**MARGIN).reproject_to_wgs84

        eastings, northings = @map.neatline.reproject_to(utm).bounds.map do |min, max|
          (min / @interval).floor..(max / @interval).ceil
        end.map do |counts|
          counts.map { |count| count * @interval }
        end

        grid = eastings.map do |easting|
          [easting].product northings.reverse
        end

        eastings, northings = [grid, grid.transpose].map.with_index do |lines, index|
          lines.inject GeoJSON::Collection.new(projection: utm) do |collection, line|
            coord = line[0][index]
            label = [coord / 100000, (coord / 1000) % 100]
            label << coord % 1000 unless @interval % 1000 == 0
            collection.add_linestring line, "label" => label, "ends" => [0, 1], "category" => index.zero? ? "easting" : "northing"
          end.reproject_to_wgs84.clip(utm_geometry).clip(map_geometry).explode.each do |linestring|
            linestring["ends"].delete 0 if linestring.coordinates.first.x % 6 < 0.00001
            linestring["ends"].delete 1 if linestring.coordinates.last.x % 6 < 0.00001
          end
        end

        boundary_points = GeoJSON.multilinestring(grid.transpose, projection: utm).reproject_to_wgs84.clip(utm_geometry).coordinates.map(&:first)
        boundary = GeoJSON.linestring boundary_points, properties: { "category" => "boundary" }

        [eastings, northings, boundary]
      end.tap do |collections|
        next unless @border
        mm = -0.5 * @params["stroke-width"]
        @map.neatline(mm: mm).reproject_to_wgs84.map! do |border|
          border.with_properties("category" => "edge")
        end.tap do |border|
          collections << border
        end
      end.inject(&:merge)
    end

    def label_element(labels, label_params)
      font_size = label_params["font-size"]
      parts = labels.zip(["%d\u00a0", "%02d", "\u00a0%03d"]).map do |part, format|
        format % part
      end.zip([80, 100, 80])

      text_path = REXML::Element.new("textPath")
      parts.each.with_index do |(text, percent), index|
        tspan = text_path.add_element "tspan", "font-size" => "#{percent}%"
        tspan.add_attributes "dy" => VALUE % (Labels::CENTRELINE_FRACTION * font_size) if index.zero?
        tspan.add_text text
      end

      text_length = parts.sum do |text, percent|
        Font.glyph_length text, label_params.merge("font-size" => font_size * percent / 100.0)
      end
      text_path.add_attribute "textLength", VALUE % text_length
      [text_length, text_path]
    end

    def labeling_features
      return [] if @params["unlabeled"]
      label_params = @params["labels"]
      font_size = label_params["font-size"]
      offset = -0.85 * font_size
      inset = INSET + font_size * 0.5 * Math::sin(@map.rotation.abs * Math::PI / 180)
      inset_geometry = @map.neatline(mm: -inset)

      gridlines = features.select do |linestring|
        linestring["label"]
      end
      eastings = gridlines.select do |gridline|
        gridline["category"] == "easting"
      end

      flip_eastings = eastings.partition do |easting|
        Math::atan2(*easting.coordinates.values_at(0, -1).inject(&:-)) * 180.0 / Math::PI > @map.rotation
      end.map(&:length).inject(&:>)
      eastings.each do |easting|
        easting.reverse!
        easting["ends"].map! { |index| 1 - index }
      end if flip_eastings

      gridlines.inject(GeoJSON::Collection.new(projection: @map.neatline.projection)) do |collection, gridline|
        collection << gridline.offset(offset, splits: false)
      end.clip(inset_geometry).explode.flat_map do |gridline|
        label, ends = gridline.values_at "label", "ends"
        %i[itself reverse].values_at(*ends).map do |order|
          text_length, text_path = label_element(label, label_params)
          v0, v1 = gridline.coordinates.send(order).take(2)
          fraction = text_length / (v1 - v0).norm
          v01 = v1 * fraction + v0 * (1 - fraction)
          coordinates = [v0, v01].send(order)
          GeoJSON::LineString[coordinates, "label" => text_path]
        end
      end
    end

    def to_s
      @name
    end
  end
end

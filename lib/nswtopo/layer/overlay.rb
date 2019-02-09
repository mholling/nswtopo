module NSWTopo
  module Overlay
    include Vector
    CREATE = %w[simplify tolerance]
    TOLERANCE = 0.4

    GPX_STYLES = YAML.load <<~YAML
      stroke: black
      stroke-width: 0.4
    YAML

    def get_features
      GPS.new(@path).tap do |gps|
        @simplify = true if GPS::GPX === gps
        @tolerance ||= [5, TOLERANCE * @map.scale / 1000.0].max if @simplify
      end.collection.reproject_to(@map.projection).explode.each do |feature|
        styles, folder, name = feature.values_at "styles", "folder", "name"
        styles ||= GPX_STYLES

        case feature
        when GeoJSON::LineString
          styles["stroke-linejoin"] = "round"
          if @tolerance
            simplified = feature.coordinates.douglas_peucker(@tolerance)
            smoothed = simplified.sample_at(2*@tolerance).each_cons(2).map do |segment|
              segment.along(0.5)
            end.push(simplified.last).prepend(simplified.first)
            feature.coordinates = smoothed
          end
        when GeoJSON::Polygon
          styles["stroke-linejoin"] = "miter"
        end

        categories = [folder, name].compact.reject(&:empty?).map(&method(:categorise))
        keys = styles.keys - params_for(categories.to_set).keys
        styles = styles.slice *keys

        feature.clear
        feature["category"] = categories << feature.object_id
        @params[categories.join(?\s)] = styles if styles.any?
      end
    end

    def to_s
      counts = %i[linestrings polygons].map do |type|
        features.send type
      end.reject(&:empty?).map(&:length).zip(%w[line polygon]).map do |count, word|
        "%s %s%s" % [count, word, (?s if count > 1)]
      end.join(", ")
      "%s: %s" % [@name, counts]
    end
  end
end

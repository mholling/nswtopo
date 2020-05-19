module NSWTopo
  module Feature
    include Vector, Shapefile, Log
    CREATE = %w[features]

    def get_features
      (Array === @features ? @features : [@features]).map do |args|
        case args
        when Hash then args.transform_keys(&:to_sym)
        when String then { source: args }
        else raise "#{@source.basename}: invalid or no features specified"
        end
      end.slice_before do |args|
        !args[:fallback]
      end.map do |fallbacks|
        options, collection, error = fallbacks.inject [{}, nil, nil] do |(options, *), source: nil, fallback: false, **args|
          source = @path if @path
          log_update "%s: %s" % [@name, fallback ? "failed to retrieve features, trying fallback source" : "retrieving features"]
          raise "#{@source.basename}: no feature source defined" unless source
          options.merge! args
          case
          when ArcGIS::Service === source
            layer = ArcGIS::Service.new(source).layer(**options.slice(:layer, :where, :per_page), geometry: @map.bounding_box(MARGIN), decode: true)
            break options, layer.features do |count, total|
              log_update "%s: retrieved %i of %i feature%s" % [@name, count, total, (?s if total > 1)]
            end
          # when Shapefile === source_path
          #   TODO
          end
          source_path = Pathname(source).expand_path(@source.parent)
          break options, shapefile_layer(source_path, margin: MARGIN, **options.slice(:where, :sql, :layer)) if Shapefile === source_path
          raise "#{@source.basename}: invalid feature source: #{source}"
        rescue ArcGIS::Error => error
          next options, nil, error
        end

        raise error if error
        next collection.reproject_to(@map.projection), options
      end.each do |collection, options|
        rotation_attribute, arithmetic = case options[:rotation]
        when /^90 - (\w+)$/ then [$1, true]
        when String then options[:rotation]
        end

        collection.each do |feature|
          categories = [*options[:category]].map do |category|
            Hash === category ? [*category] : [category]
          end.flatten(1).map do |attribute, substitutions|
            value = feature.fetch(attribute, attribute)
            substitutions ? substitutions.fetch(value, value) : value
          end

          options[:sizes].tap do |mm, max = 9|
            unit = 0.001 * (mm == true ? 5 : mm) * @map.scale
            case feature
            when GeoJSON::LineString, GeoJSON::MultiLineString
              size = (Math::log2(feature.length) - Math::log2(unit)).ceil rescue 0
              categories << size.clamp(0, max)
            when GeoJSON::Polygon, GeoJSON::MultiPolygon
              size = (0.5 * Math::log2(feature.area) - Math::log2(unit)).ceil rescue 0
              categories << size.clamp(0, max)
            end
          end if options[:sizes]

          rotation = case feature
          when GeoJSON::Point, GeoJSON::MultiPoint
            value = begin
              Float feature.fetch(rotation_attribute)
            rescue KeyError, TypeError, ArgumentError
              0.0
            end
            categories << (value.zero? ? "unrotated" : "rotated")
            arithmetic ? 90 - value : value
          end if rotation_attribute

          labels = Array(options[:label]).map do |attribute|
            feature.fetch(attribute, attribute)
          end.map(&:to_s).reject(&:empty?)

          categories = categories.map(&:to_s).reject(&:empty?).map(&method(:categorise))
          properties = {}
          properties["category"] = categories if categories.any?
          properties["label"] = labels if labels.any?
          properties["draw"] = false if options[:draw] == false
          properties["draw"] = false if @name =~ /[-_]labels$/
          properties["rotation"] = rotation if rotation

          feature.properties.replace properties
        end
      end.map(&:first).inject(&:merge).rename(@name)
    end
  end
end

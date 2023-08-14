module NSWTopo
  module Feature
    include VectorRender, Log
    CREATE = %w[features]

    def get_features
      (Array === @features ? @features : [@features]).map do |args|
        case args
        when Hash then args.transform_keys(&:to_sym)
        when String then { source: args }
        else raise "#{@source.basename}: invalid or no features specified"
        end
      end.slice_before do |args|
        !args.delete(:fallback)
      end.map do |fallbacks|
        fallbacks.each.with_object({})
      end.map do |fallbacks|
        args, options = *fallbacks.next
        source, error = args.delete(:source), nil
        source = @path if @path
        log_update "%s: %s" % [@name, options.any? ? "failed to retrieve features, trying fallback source" : "retrieving features"]
        raise "#{@source.basename}: no feature source defined" unless source
        source_path = Pathname(source).expand_path(@source.parent)
        options.merge! args
        collection = case
        when ArcGIS::Service === source
          layer = ArcGIS::Service.new(source).layer(**options.slice(:layer, :where), geometry: @map.neatline(**MARGIN).bbox, decode: true)
          layer.features(**options.slice(:per_page)) do |count, total|
            log_update "%s: retrieved %i of %i feature%s" % [@name, count, total, (?s if total > 1)]
          end.reproject_to(@map.neatline.projection)
        when Shapefile::Source === source_path
          layer = Shapefile::Source.new(source_path).layer(**options.slice(:where, :sql, :layer), geometry: @map.neatline(**MARGIN), projection: @map.neatline.projection)
          layer.features
        else
          raise "#{@source.basename}: invalid feature source: #{source}"
        end
        next collection, options
      rescue ArcGIS::Connection::Error => error
        retry
      rescue StopIteration
        raise error
      end.each do |collection, options|
        rotation_attribute, arithmetic = case options[:rotation]
        when /^90 - (\w+)$/ then [$1, true]
        when String then options[:rotation]
        end

        collection.each do |feature|
          categories = [*options[:category]].flat_map do |category|
            Hash === category ? [*category] : [category]
          end.map do |attribute, substitutions|
            value = feature.fetch(attribute, attribute)
            substitutions ? substitutions.fetch(value, value) : value
          end

          options[:sizes].tap do |mm, max = 9|
            unit = (mm == true ? 5 : mm)
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

          dual = options[:dual].then do |attribute|
            feature.fetch(attribute, attribute) if attribute
          end

          categories = categories.map(&:to_s).reject(&:empty?).map(&method(:categorise))
          properties = {}
          properties["category"] = categories if categories.any?
          properties["label"] = labels if labels.any?
          properties["dual"] = dual if dual
          properties["draw"] = false if options[:draw] == false
          properties["draw"] = false if @name =~ /[-_]labels$/ && !options.key?(:draw)
          properties["rotation"] = rotation if rotation

          feature.properties.replace properties
        end
      end.map(&:first).inject(&:merge).rename(@name)
    end
  end
end

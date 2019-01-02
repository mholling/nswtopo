module NSWTopo
  module Feature
    include Vector
    include ArcGISServer
    include Shapefile
    CREATE = %w[features]

    def get_features
      (Array === @features ? @features : [ @features ]).map do |args|
        case args
        when Hash then args.transform_keys(&:to_sym)
        when String then { source: args }
        else raise "#{@name}: invalid or no features specified"
        end
      end.slice_before do |args|
        !args[:fallback]
      end.map do |fallbacks|
        options, collection, error = fallbacks.inject [ {}, nil, nil ] do |(options, *), args|
          warn "\r\033[K#{@name}: failed to retrieve features, trying fallback source" if args[:fallback]
          break options.merge!(args), case source = args.delete(:source)
          when ArcGISServer
            arcgis_layer source, margin: MARGIN, **options.slice(:where, :layer, :per_page) do |index, total|
              print "\r\033[K#{@name}: retrieved #{index} of #{total} features"
            end
          when Shapefile
            shapefile_layer source, margin: MARGIN, **options.slice(:where, :layer)
          else raise "#{@name}: invalid feature source: #{source}"
          end
        rescue ArcGISServer::Error => error
          next options, nil, error
        end

        raise error if error
        puts "\r\033[K%s: retrieved %i feature%s" % [ @name, collection.count, (?s unless collection.one?) ]

        next collection.reproject_to(@map.projection), options
      end.each do |collection, options|
        collection.each do |feature|
          categories = [ *options[:category] ].map do |category|
            Hash === category ? [ *category ] : [ category ]
          end.flatten(1).map do |attribute, substitutions|
            value = feature.properties.fetch(attribute, attribute)
            substitutions ? substitutions.fetch(value, value) : value
          end

          options[:sizes].tap do |mm, max = 9|
            unit = 0.001 * (mm == true ? 5 : mm) * @map.scale
            case feature
            when GeoJSON::LineString, GeoJSON::MultiLineString
              size = (Math::log2(feature.length) - Math::log2(unit)).ceil rescue 0
              categories << [ [ 0, size ].max, max ].min
            when GeoJSON::Polygon, GeoJSON::MultiPolygon
              size = (0.5 * Math::log2(feature.area) - Math::log2(unit)).ceil rescue 0
              categories << [ [ 0, size ].max, max ].min
            end
          end if options[:sizes]

          angle = options[:rotation].yield_self do |attribute, sense|
            case feature
            when GeoJSON::Point, GeoJSON::MultiPoint
              value = begin
                Float feature.properties.fetch(attribute)
              rescue KeyError, TypeError, ArgumentError
                0.0
              end
              categories << "no-angle" if value.zero?
              "arithmetic" == sense ? value : 90 - value
            end
          end if options[:rotation]

          labels = [ *options[:label] ].map do |attribute|
            feature.properties.fetch(attribute, attribute)
          end.map(&:to_s).reject(&:empty?)

          categories, properties = categories.map(&:to_s).reject(&:empty?).map(&:to_category), {}
          properties["categories"] = categories if categories.any?
          properties["labels"] = labels if labels.any?
          properties["nodraw"] = true if options[:nodraw]
          properties["nodraw"] = true if /-labels$/ === @name
          properties["angle"] = angle if angle

          feature.properties.replace properties
        end
      end.map(&:first).inject(&:merge)
    end
  end
end

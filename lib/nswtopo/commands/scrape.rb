module NSWTopo
  def scrape(url, path, coords: nil, name: nil, epsg: nil, paginate: nil, concat: nil, **options)
    flags  = %w[-skipfailures]
    flags += %W[-t_srs epsg:#{epsg}] if epsg
    flags += %W[-nln #{name}] if name

    format_flags = case path.to_s
    when Shapefile::Source then %w[-update -overwrite]
    when /\.sqlite3?$/     then %w[-f SQLite -dsco SPATIALITE=YES]
    when /\.db$/           then %w[-f SQLite -dsco SPATIALITE=YES]
    when /\.gpkg$/         then %w[-f GPKG]
    when /\.tab$/          then ["-f", "MapInfo File"]
    else                        ["-f", "ESRI Shapefile"]
    end

    options.merge! case path.to_s
    when /\.sqlite3?$/ then { mixed: concat, launder: true }
    when /\.db$/       then { mixed: concat, launder: true }
    when /\.gpkg$/     then { mixed: concat, launder: true }
    when /\.tab$/      then { }
    else                    { truncate: 10 }
    end

    options[:geometry] = GeoJSON.multipoint(coords).bbox if coords

    log_update "nswtopo: contacting server"
    layer = ArcGIS::Service.new(url).layer(**options)

    queue = Queue.new
    thread = Thread.new do
      while page = queue.pop
        *, status = Open3.capture3 *%W[ogr2ogr #{path} /vsistdin/], *flags, *format_flags, stdin_data: page.to_json
        format_flags = %w[-update -append]
        queue.close unless status.success?
      end
      status
    end

    total_features, percent = "%i feature%s", "%%.%if%%%%"
    Enumerator.new do |yielder|
      hold, ok, count = [], nil, 0
      layer.paged(per_page: paginate).tap do
        total_features %= [layer.count, (?s unless layer.count == 1)]
        percent %= layer.count < 1000 ? 0 : layer.count < 10000 ? 1 : 2
        log_update "nswtopo: retrieving #{total_features}"
      end.each do |page|
        log_update "nswtopo: retrieving #{percent} of #{total_features}" % [100.0 * (count += page.count) / layer.count]
        next hold << page if concat
        next yielder << page if ok
        next hold << page if page.all? do |feature|
          feature.properties.values.any?(&:nil?)
        end
        yielder << page
        ok = true
      end
      next hold.inject(yielder, &:<<) if ok && !concat
      next yielder << hold.inject(&:merge!) if hold.any?
    end.inject(queue) do |queue, page|
      queue << page
    rescue ClosedQueueError
      break queue
    end.close

    log_update "nswtop: saving #{total_features}"
    raise "error while saving features" unless thread.value&.success?
    log_success "saved #{total_features}"
  rescue ArcGIS::Map::NoUniqueFieldError
    raise OptionParser::InvalidOption, "--unique required for this layer"
  rescue ArcGIS::Map::NoGeometryError
    raise OptionParser::InvalidOption, "--coords not available for this layer"
  rescue ArcGIS::Query::UniqueFieldError
    raise OptionParser::InvalidOption, "--unique not available for this layer"
  rescue ArcGIS::Service::InvalidURLError
    raise OptionParser::InvalidArgument, url
  end
end

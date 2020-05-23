module NSWTopo
  def scrape(url, path, coords: nil, name: nil, epsg: nil, paginate: nil, concat: nil, **options)
    flags  = %w[-skipfailures]
    flags += %W[-t_srs epsg:#{epsg}] if epsg
    flags += %W[-nln #{name}] if name

    format_flags = case path.to_s
    when Shapefile     then %w[-update -overwrite]
    when /\.sqlite3?$/ then %w[-f SQLite -dsco SPATIALITE=YES]
    when /\.db$/       then %w[-f SQLite -dsco SPATIALITE=YES]
    when /\.gpkg$/     then %w[-f GPKG]
    when /\.tab$/      then ["-f", "MapInfo File"]
    else                    ["-f", "ESRI Shapefile"]
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

    log_update "nswtopo: retrieving #{layer.count} feature#{?s unless layer.count == 1}"
    percent = layer.count < 1000 ? "%.0f%%" : layer.count < 10000 ? "%.1f%%" : "%.2f%%"
    message = "nswtopo: saving #{percent} of #{layer.count} feature#{?s unless layer.count == 1}"

    queue, count = Queue.new, 0
    thread = Thread.new do
      while page = queue.pop
        log_update message % [100.0 * (count + page.count) / layer.count]
        *, status = Open3.capture3 *%W[ogr2ogr #{path} /vsistdin/], *flags, *format_flags, stdin_data: page.to_json
        count, format_flags = count + page.count, %w[-update -append]
        queue.close unless status.success?
      end
      status
    end

    layer.paged(per_page: paginate).yield_self do |pages|
      concat ? [pages.inject(&:merge!)] : pages
    end.inject(queue) do |queue, page|
      queue << page
    rescue ClosedQueueError
      break queue
    end.close

    raise "error while saving features" unless thread.value.success?
    log_success "saved #{count} feature#{?s unless count == 1}"
  rescue ArcGIS::Map::NoUniqueFieldError
    raise OptionParser::InvalidOption, "--unique required for this layer"
  rescue ArcGIS::Map::NoGeometryError
    raise OptionParser::InvalidOption, "--coords not available for this layer"
  rescue ArcGIS::Query::UniqueFieldError
    raise OptionParser::InvalidOption, "--unique not available for this layer"
  end
end

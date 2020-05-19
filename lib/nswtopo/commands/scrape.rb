module NSWTopo
  def scrape(url, path, coords: nil, format: nil, name: nil, epsg: nil, paginate: nil, concat: nil, **options)
    flags  = %w[-skipfailures]
    flags += %W[-t_srs epsg:#{epsg}] if epsg
    flags += %W[-nln #{name}] if name

    case format || path.extname[1..-1]
    when "sqlite", "sqlite3", "db"
      format_flags = %w[-f SQLite -dsco SPATIALITE=YES]
      options.merge! mixed: concat, launder: true
    when "gpkg"
      format_flags = %w[-f GPKG]
      options.merge! mixed: concat, launder: true
    when "tab"
      format_flags = ["-f", "MapInfo File"]
    else
      format_flags = ["-f", "ESRI Shapefile"]
      options.merge! truncate: 10
    end

    options[:geometry] = GeoJSON.multipoint(coords).bbox if coords

    log_update "nswtopo: retrieving features"
    layer = ArcGIS::Service.new(url).layer(**options)

    percent = layer.count < 10000 ? "%.0f%%" : layer.count < 100000 ? "%.1f%%" : "%.2f%%"
    message = "nswtopo: saving #{percent} of #{layer.count} feature#{?s unless layer.count == 1}"

    queue, count = Queue.new, 0
    thread = Thread.new do
      while page = queue.pop
        log_update message % [100.0 * count / layer.count]
        *, status = Open3.capture3 *%W[ogr2ogr #{path} /vsistdin/], *flags, *format_flags, stdin_data: page.to_json
        count, format_flags = count + page.count, %w[-update -append]
        queue.close unless status.success?
      end
      status
    end

    layer.pages(per_page: paginate).yield_self do |pages|
      concat ? [pages.inject(&:merge!)] : pages
    end.inject(queue) do |queue, page|
      queue << page
    rescue ClosedQueueError
      break queue
    end.close

    raise "error while saving features" unless thread.value.success?
    log_success "saved #{count} feature#{?s unless layer.count == 1}"
  end
end

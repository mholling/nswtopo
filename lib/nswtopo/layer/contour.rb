module NSWTopo
  module Contour
    include VectorRender, DEM, Log
    CREATE = %w[interval index auxiliary smooth simplify thin density min-length no-depression knolls fill]
    DEFAULTS = YAML.load <<~YAML
      interval: 5
      smooth: 0.2
      density: 4.0
      min-length: 2.0
      knolls: 0.2
      section: 100
      stroke: hsl(40,100%,25%)
      stroke-width: 0.08
      Auxiliary:
        stroke-dasharray: 0.5 0.5
        stroke-dashoffset: 0.5
      Depression:
        symbolise:
          interval: 2.0
          line:
            stroke-width: 0.12
            y2: -0.3
      labels:
        font-size: 1.4
        letter-spacing: 0.05
        orientation: downhill
        collate: true
        min-radius: 5
        max-turn: 20
        sample: 10
        minimum-area: 70
        separation:
          self: 40
          other: 15
          along: 100
    YAML

    def margin
      { mm: [3 * @smooth, 1].max }
    end

    def check_geos!
      json = OS.ogr2ogr "-dialect", "SQLite", "-sql", "SELECT geos_version() AS version", "-f", "GeoJSON", "-lco", "RFC7946=NO", "/vsistdout/", "/vsistdin/" do |stdin|
        stdin.write GeoJSON::Collection.new.to_json
      end
      raise unless version = JSON.parse(json).dig("features", 0, "properties", "version")
      raise unless (version.split(?-).first.split(?.).map(&:to_i) <=> [3, 3]) >= 0
    rescue OS::Error, JSON::ParserError, RuntimeError
      raise "contour thinning requires GDAL with SpatiaLite and GEOS support"
    end

    def get_features
      @simplify ||= [@map.to_mm(0.5 * @interval) / Math::tan(Math::PI * 85 / 180), 0.05].min
      @index ||= 10 * @interval
      @params = {
        "Index" => { "stroke-width" => 2 * @params["stroke-width"] },
        "labels" => { "fill" => @fill || @params["stroke"] }
      }.deep_merge(@params)

      check_geos! if @thin
      raise "%im index interval not a multiple of %im contour interval" % [@index, @interval] unless @index % @interval == 0

      Dir.mktmppath do |temp_dir|
        dem_path, blur_path = temp_dir / "dem.tif", temp_dir / "dem.blurred.tif"

        if @smooth.zero?
          get_dem temp_dir, blur_path
        else
          get_dem temp_dir, dem_path
          blur_dem dem_path, blur_path
        end

        db_flags = @thin ? %w[-f SQLite -dsco SPATIALITE=YES] : ["-f", "ESRI Shapefile"]
        db_path = temp_dir / "contour"

        log_update "%s: generating contour lines" % @name
        json = OS.gdal_contour "-q", "-a", "elevation", "-i", @interval, "-f", "GeoJSON", "-lco", "RFC7946=NO", blur_path, "/vsistdout/"
        contours = GeoJSON::Collection.load(json, projection: @map.projection).map! do |feature|
          id, elevation = feature.values_at "ID", "elevation"
          properties = { "id" => id, "elevation" => elevation, "modulo" => elevation % @index, "depression" => feature.closed? && feature.anticlockwise? ? 1 : 0}
          feature.with_properties(properties)
        end

        if @no_depression.nil?
          candidates = contours.select do |feature|
            feature["depression"] == 1
          end
          index = RTree.load(candidates, &:bounds)

          contours.reject! do |feature|
            next unless feature["depression"] == 1
            index.search(feature.bounds).none? do |other|
              next if other == feature
              feature.to_polygon.contains?(other.first) || other.to_polygon.contains?(feature.first)
            end
          end
        end

        contours.reject! do |feature|
          feature.closed? &&
          feature.bounds.all? { |min, max| max - min < @knolls }
        end.reject! do |feature|
          feature["elevation"].zero?
        end

        contours.each_slice(100).inject(nil) do |update, features|
          OS.ogr2ogr "-a_srs", @map.projection, "-nln", "contour", *update, "-simplify", @simplify, *db_flags, db_path, "GeoJSON:/vsistdin/" do |stdin|
            stdin.write GeoJSON::Collection.new(projection: @map.projection, features: features).to_json
          end
          %w[-update -append]
        end

        if @thin
          slope_tif_path = temp_dir / "slope.tif"
          slope_vrt_path = temp_dir / "slope.vrt"

          log_update "%s: generating slope masks" % @name
          OS.gdaldem "slope", blur_path, slope_tif_path, "-compute_edges"
          json = OS.gdalinfo "-json", slope_tif_path
          width, height = JSON.parse(json)["size"]
          srcwin = [ -2, -2, width + 4, height + 4 ]
          OS.gdal_translate "-srcwin", *srcwin, "-a_nodata", "none", "-of", "VRT", slope_tif_path, slope_vrt_path

          multiplier = @index / @interval
          Enumerator.new do |yielder|
            keep = 0...multiplier
            until keep.one?
              keep, drop = keep.count.even? ? keep.each_slice(2).entries.transpose : [[0], keep.drop(1)]
              yielder << drop
            end
          end.inject(multiplier) do |count, drop|
            angle = Math::atan(@index * @density / count) * 180.0 / Math::PI
            mask_path = temp_dir / "mask.#{count}.sqlite"

            OS.gdal_contour "-nln", "ring", "-a", "angle", "-fl", angle, *db_flags, slope_vrt_path, mask_path

            OS.ogr2ogr "-update", "-nln", "mask", "-nlt", "MULTIPOLYGON", mask_path, mask_path, "-dialect", "SQLite", "-sql", <<~SQL
              SELECT
                ST_Buffer(ST_Buffer(ST_Polygonize(geometry), #{0.5 * @min_length}, 6), #{-0.5 * @min_length}, 6) AS geometry
              FROM ring
            SQL

            drop.each do |index|
              OS.ogr2ogr "-nln", "mask", "-update", "-append", "-explodecollections", "-q", db_path, mask_path, "-dialect", "SQLite", "-sql", <<~SQL
                SELECT geometry, #{index * @interval} AS modulo
                FROM mask
              SQL
            end

            count - drop.count
          end

          log_update "%s: thinning contour lines" % @name
          OS.ogr2ogr "-nln", "divided", "-update", "-explodecollections", db_path, db_path, "-dialect", "SQLite", "-sql", <<~SQL
            WITH intersecting(contour, mask) AS (
              SELECT contour.rowid, mask.rowid
              FROM contour
              INNER JOIN mask
              ON
                mask.modulo = contour.modulo AND
                contour.rowid IN (
                  SELECT rowid FROM SpatialIndex
                  WHERE
                    f_table_name = 'contour' AND
                    search_frame = mask.geometry
                ) AND
                ST_Relate(contour.geometry, mask.geometry, 'T********')
            )

            SELECT contour.geometry, contour.id, contour.elevation, contour.modulo, contour.depression, 1 AS unmasked, 1 AS unaltered
            FROM contour
            LEFT JOIN intersecting ON intersecting.contour = contour.rowid
            WHERE intersecting.contour IS NULL

            UNION SELECT ExtractMultiLinestring(ST_Difference(contour.geometry, ST_Collect(mask.geometry))) AS geometry, contour.id, contour.elevation, contour.modulo, contour.depression, 1 AS unmasked, 0 AS unaltered
            FROM contour
            INNER JOIN intersecting ON intersecting.contour = contour.rowid
            INNER JOIN mask ON intersecting.mask = mask.rowid
            GROUP BY contour.rowid
            HAVING min(ST_Relate(contour.geometry, mask.geometry, '**T******'))

            UNION SELECT ExtractMultiLinestring(ST_Intersection(contour.geometry, ST_Collect(mask.geometry))) AS geometry, contour.id, contour.elevation, contour.modulo, contour.depression, 0 AS unmasked, 0 AS unaltered
            FROM contour
            INNER JOIN intersecting ON intersecting.contour = contour.rowid
            INNER JOIN mask ON intersecting.mask = mask.rowid
            GROUP BY contour.rowid
          SQL

          OS.ogr2ogr "-nln", "thinned", "-update", "-explodecollections", db_path, db_path, "-dialect", "SQLite", "-sql", <<~SQL
            SELECT ST_LineMerge(ST_Collect(geometry)) AS geometry, id, elevation, modulo, depression, unaltered
            FROM divided
            WHERE unmasked OR ST_Length(geometry) < #{@min_length}
            GROUP BY id, elevation, modulo, unaltered
          SQL

          OS.ogr2ogr "-nln", "contour", "-update", "-overwrite", db_path, db_path, "-dialect", "SQLite", "-sql", <<~SQL
            SELECT geometry, id, elevation, modulo, depression
            FROM thinned
            WHERE unaltered OR ST_Length(geometry) > #{@min_length}
          SQL
        end

        json = OS.ogr2ogr "-f", "GeoJSON", "-lco", "RFC7946=NO", "/vsistdout/", db_path, "contour"
        GeoJSON::Collection.load(json, projection: @map.projection).map! do |feature|
          elevation, modulo, depression = feature.values_at "elevation", "modulo", "depression"
          category = case
          when @auxiliary && elevation % (2 * @interval) != 0 then %w[Auxiliary]
          when modulo.zero? then %w[Index]
          else %w[Standard]
          end
          category << "Depression" if depression == 1

          properties = Hash[]
          properties["elevation"] = elevation
          properties["category"] = category
          properties["label"] = elevation.to_i.to_s if modulo.zero?
          feature.with_properties(properties)
        end
      end
    end

    def to_s
      elevations = features.map do |feature|
        [feature["elevation"], feature["category"].include?("Index")]
      end.uniq.sort_by(&:first)
      range = elevations.map(&:first).minmax
      interval, index = %i[itself last].map do |selector|
        elevations.select(&selector).map(&:first).each_cons(2).map { |e0, e1| e1 - e0 }.min
      end
      [["%im intervals", interval], ["%im indices", index], ["%im-%im elevation", (range if range.all?)]].select(&:last).map do |label, value|
        label % value
      end.join(", ").prepend("%s: " % @name)
    end
  end
end

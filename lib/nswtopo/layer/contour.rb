module NSWTopo
  module Contour
    include Vector, DEM, Log
    CREATE = %w[interval index smooth simplify thin density min-length no-depression knolls fill]
    DEFAULTS = YAML.load <<~YAML
      interval: 5
      smooth: 0.2
      density: 4.0
      min-length: 2.0
      knolls: 0.2
      section: 100
      stroke: "#805100"
      stroke-width: 0.08
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
        separation: 40
        separation-all: 15
        separation-along: 100
    YAML

    def margin
      { mm: [3 * @smooth, 1].min }
    end

    def check_geos!
      json = OS.ogr2ogr "-dialect", "SQLite", "-sql", "SELECT geos_version() AS version", "-f", "GeoJSON", "/vsistdout/", "/vsistdin/" do |stdin|
        stdin.write GeoJSON::Collection.new.to_json
      end
      raise unless version = JSON.parse(json).dig("features", 0, "properties", "version")
      raise unless (version.split(?-).first.split(?.).map(&:to_i) <=> [3, 3]) >= 0
    rescue OS::Error, JSON::ParserError, RuntimeError
      raise "contour thinning requires GDAL with SpatiaLite and GEOS support"
    end

    def get_features
      @simplify ||= [0.5 * @interval / Math::tan(Math::PI * 85 / 180), 0.001 * 0.05 * @map.scale].min
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
        contours = GeoJSON::Collection.load json, @map.projection

        if @no_depression.nil?
          candidates = contours.select do |feature|
            feature.coordinates.last == feature.coordinates.first &&
            feature.coordinates.anticlockwise?
          end.each do |feature|
            feature["depression"] = 1
          end
          index = RTree.load(candidates, &:bounds)

          contours.reject! do |feature|
            next unless feature["depression"] == 1
            index.search(feature.bounds).none? do |other|
              next if other == feature
              feature.coordinates.first.within?(other.coordinates) ||
              other.coordinates.first.within?(feature.coordinates)
            end
          end
        end

        contours.reject! do |feature|
          feature.coordinates.last == feature.coordinates.first &&
          feature.bounds.all? { |min, max| max - min < @knolls * @map.scale / 1000.0 }
        end

        contours.each do |feature|
          id, elevation, depression = feature.values_at "ID", "elevation", "depression"
          feature.properties.replace("id" => id, "elevation" => elevation, "modulo" => elevation % @index, "depression" => depression || 0)
        end

        contours.reject! do |feature|
          feature["elevation"].zero?
        end

        OS.ogr2ogr "-a_srs", @map.projection, "-nln", "contour", "-simplify", @simplify, *db_flags, db_path, "GeoJSON:/vsistdin/" do |stdin|
          stdin.write contours.to_json
        end

        if @thin
          slope_tif_path = temp_dir / "slope.tif"
          slope_vrt_path = temp_dir / "slope.vrt"
          min_length = @min_length * @map.scale / 1000.0

          log_update "%s: generating slope masks" % @name
          OS.gdaldem "slope", blur_path, slope_tif_path, "-compute_edges"
          json = OS.gdalinfo "-json", slope_tif_path
          width, height = JSON.parse(json)["size"]
          srcwin = [ -2, -2, width + 4, height + 4 ]
          OS.gdal_translate "-srcwin", *srcwin, "-a_nodata", "none", "-of", "VRT", slope_tif_path, slope_vrt_path

          multiplier = @index / @interval
          case multiplier
          when  4 then [ [1,3], 2 ]
          when  5 then [ [1,4], [2,3] ]
          when  6 then [ [1,4], [2,5], 3 ]
          when  7 then [ [2,5], [1,3,6], 4 ]
          when  8 then [ [1,3,5,7], [2,6], 4 ]
          when  9 then [ [1,4,7], [2,5,8], [3,6] ]
          when 10 then [ [2,5,8], [1,4,6,9], [3,7] ]
          else raise "contour thinning not available for specified index interval"
          end.inject(multiplier) do |count, (*drop)|
            angle = Math::atan(1000.0 * @index * @density / @map.scale / count) * 180.0 / Math::PI
            mask_path = temp_dir / "mask.#{count}.sqlite"

            OS.gdal_contour "-nln", "ring", "-a", "angle", "-fl", angle, *db_flags, slope_vrt_path, mask_path

            OS.ogr2ogr "-update", "-nln", "mask", "-nlt", "MULTIPOLYGON", mask_path, mask_path, "-dialect", "SQLite", "-sql", <<~SQL
              SELECT
                ST_Buffer(ST_Buffer(ST_Polygonize(geometry), #{0.5 * min_length}, 6), #{-0.5 * min_length}, 6) AS geometry
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
            WHERE unmasked OR ST_Length(geometry) < #{min_length}
            GROUP BY id, elevation, modulo, unaltered
          SQL

          OS.ogr2ogr "-nln", "contour", "-update", "-overwrite", db_path, db_path, "-dialect", "SQLite", "-sql", <<~SQL
            SELECT geometry, id, elevation, modulo, depression
            FROM thinned
            WHERE unaltered OR ST_Length(geometry) > #{min_length}
          SQL
        end

        json = OS.ogr2ogr "-f", "GeoJSON", "-lco", "RFC7946=NO", "/vsistdout/", db_path, "contour"
        GeoJSON::Collection.load(json, @map.projection).each do |feature|
          elevation, modulo, depression = feature.values_at "elevation", "modulo", "depression"
          category = modulo.zero? ? %w[Index] : %w[Standard]
          category << "Depression" if depression == 1
          feature.clear
          feature["elevation"] = elevation
          feature["category"] = category
          feature["label"] = elevation.to_i.to_s if modulo.zero?
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

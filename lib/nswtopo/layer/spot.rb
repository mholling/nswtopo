module NSWTopo
  module Spot
    include Vector, DEM, Log
    CREATE = %w[spacing smooth prefer]
    DEFAULTS = YAML.load <<~YAML
      spacing: 15
      smooth: 0.2
      symbol:
        circle:
          r: 0.2
          stroke: none
          fill: black
      labels:
        font-family: Arial, Helvetica, sans-serif
        font-size: 1.4
        margin: 0.7
        position: [right, above, below, left, aboveright, belowright, aboveleft, belowleft]
    YAML
    NOISE_MM = 2.0 # TODO: noise sensitivity should depend on contour interval

    def margin
      { mm: 3 * @smooth }
    end

    def raster_values(path, pixels)
      OS.gdallocationinfo "-valonly", path do |stdin|
        pixels.each { |pixel| stdin.puts "%i %i" % pixel }
      end.each_line.map do |line|
        Float(line) rescue nil
      end
    end

    def raster_locations(path, pixels)
      OS.gdaltransform "-output_xy", path do |stdin|
        pixels.each { |pixel| stdin.puts "%i %i" % pixel }
      end.each_line.map do |line|
        line.chomp.split(?\s).map(&:to_f)
      end
    end

    module Candidate
      module PreferKnolls
        def ordinal; [conflicts.size, -self["elevation"]] end
      end

      module PreferSaddles
        def ordinal; [conflicts.size, self["elevation"]] end
      end

      module PreferNeither
        def ordinal; conflicts.size end
      end

      def conflicts
        @conflicts ||= Set[]
      end

      def <=>(other)
        self.ordinal <=> other.ordinal
      end

      def bounds(buffer = 0)
        coordinates.map { |coordinate| [coordinate - buffer, coordinate + buffer] }
      end
    end

    def ordering
      @ordering ||= case @prefer
      when "knolls" then Candidate::PreferKnolls
      when "saddles" then Candidate::PreferSaddles
      else Candidate::PreferNeither
      end
    end

    def candidates
      @candidates ||= Dir.mktmppath do |temp_dir|
        raw_path = temp_dir / "raw.tif"
        dem_path = temp_dir / "dem.tif"
        aspect_path = temp_dir / "aspect.bil"

        if @smooth.zero?
          get_dem temp_dir, dem_path
        else
          get_dem temp_dir, raw_path
          blur_dem raw_path, dem_path
        end

        log_update "%s: calculating aspect map" % @name
        OS.gdaldem "aspect", dem_path, aspect_path, "-trigonometric"

        Enumerator.new do |yielder|
          aspect = ESRIHdr.new aspect_path, -9999
          indices = [-1, 0, 1].map do |row|
            [-1, 0, 1].map do |col|
              row * aspect.ncols + col - 1
            end
          end.flatten.values_at(0,3,6,7,8,5,2,1,0)

          aspect.nrows.times do |i|
            log_update "%s: finding flat areas: %.1f%%" % [@name, 100.0 * i / aspect.nrows]
            aspect.ncols.times do |j|
              indices.map!(&:next)
              next if i < 1 || j < 1 || i > aspect.nrows - 2 || j > aspect.ncols - 2
              ring = aspect.values.values_at *indices
              next if ring.any?(&:nil?)
              anticlockwise = ring.each_cons(2).map do |a1, a2|
                (a2 - a1) % 360 < 180
              end
              yielder << [[j + 1, i + 1], true] if anticlockwise.all?
              yielder << [[j + 1, i + 1], false] if anticlockwise.none?
            end
          end
        end.group_by(&:last).flat_map do |knoll, group|
          pixels = group.map(&:first)
          locations = raster_locations dem_path, pixels
          elevations = raster_values dem_path, pixels

          locations.zip(elevations).map do |coordinates, elevation|
            GeoJSON::Point.new coordinates, "knoll" => knoll, "elevation" => elevation
          end.each do |feature|
            feature.extend Candidate, ordering
          end
        end
      end
    end

    def get_features
      selected, rejected, remaining = [], Set[], AVLTree.new
      index = RTree.load(candidates, &:bounds)

      log_update "%s: choosing candidates" % @name
      candidates.to_set.each do |candidate|
        buffer = NOISE_MM * @map.scale / 1000.0
        index.search(candidate.bounds(buffer)).each do |other|
          next unless candidate["knoll"] ^ other["knoll"]
          next if [candidate, other].map(&:coordinates).distance > buffer
          rejected << candidate << other
        end
      end.difference(rejected).each do |candidate|
        buffer = @spacing * @map.scale / 1000.0
        index.search(candidate.bounds(buffer)).each do |other|
          next if other == candidate
          next if rejected === other
          next if [candidate, other].map(&:coordinates).distance > buffer
          candidate.conflicts << other
        end
      end.each do |candidate|
        remaining << candidate
      end

      while chosen = remaining.first
        log_update "%s: choosing candidates: %i remaining" % [@name, remaining.count]
        selected << chosen
        removals = Set[chosen] | chosen.conflicts
        removals.each do |candidate|
          remaining.delete candidate
        end.map(&:conflicts).inject(&:|).subtract(removals).each do |other|
          remaining.delete other
          other.conflicts.subtract removals
          remaining.insert other
        end
      end

      selected.each do |feature|
        feature.properties.replace "label" => feature["elevation"].round
      end.yield_self do |features|
        GeoJSON::Collection.new @map.projection, features
      end
    end
  end
end

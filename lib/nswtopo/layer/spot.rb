module NSWTopo
  module Spot
    include Vector, DEM, Log
    CREATE = %w[spacing smooth prefer extent]
    DEFAULTS = YAML.load <<~YAML
      spacing: 15
      smooth: 0.2
      extent: 4
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
      attr_accessor :elevation, :knoll

      module PreferKnolls
        def ordinal; [conflicts.size, -elevation] end
      end

      module PreferSaddles
        def ordinal; [conflicts.size, elevation] end
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

    def pixels_knolls(dem_path, &block)
      Enumerator.new do |yielder|
        log_update "%s: calculating aspect map" % @name
        aspect_path = dem_path.sub_ext ".bil"
        OS.gdaldem "aspect", dem_path, aspect_path, "-trigonometric"
        aspect = ESRIHdr.new aspect_path, -9999

        offsets = [-1..1, -1..1].map(&:entries).inject(&:product).map do |row, col|
          row * aspect.ncols + col - 1
        end.values_at(0,3,6,7,8,5,2,1,0)

        aspect.nrows.times do |row|
          log_update "%s: finding flat areas: %.1f%%" % [@name, 100.0 * (row + 1) / aspect.nrows]
          aspect.ncols.times do |col|
            offsets.map!(&:next)
            next if row < 1 || col < 1 || row >= aspect.nrows - 1 || col >= aspect.ncols - 1
            next if block&.call col, row
            ccw, cw = offsets.each_cons(2).inject([true, true]) do |(ccw, cw), (o1, o2)|
              break unless ccw || cw
              a1, a2 = aspect.values.values_at o1, o2
              break unless a1 && a2
              (a2 - a1) % 360 < 180 ? [ccw, false] : [false, cw]
            end
            yielder << [[col, row], true] if ccw
            yielder << [[col, row], false] if cw
          end
        end
      end
    end

    def candidates
      @candidates ||= Dir.mktmppath do |temp_dir|
        raw_path = temp_dir / "raw.tif"
        dem_hr_path = temp_dir / "dem.hr.tif"
        dem_lr_path = temp_dir / "dem.lr.tif"

        if @smooth.zero?
          get_dem temp_dir, dem_hr_path
        else
          get_dem temp_dir, raw_path
          blur_dem raw_path, dem_hr_path
        end

        low_resolution = 0.5 * @extent * @map.scale / 1000.0
        OS.gdalwarp "-r", "med", "-tr", low_resolution, low_resolution, dem_hr_path, dem_lr_path

        mask = pixels_knolls(dem_lr_path).map(&:first).to_set
        pixels, knolls = pixels_knolls(dem_hr_path) do |col, row|
          !mask.include? [(col * @resolution / low_resolution).floor, (row * @resolution / low_resolution).floor]
        end.entries.transpose

        locations = raster_locations dem_hr_path, pixels
        elevations = raster_values dem_hr_path, pixels

        locations.zip(elevations, knolls).map do |coordinates, elevation, knoll|
          GeoJSON::Point.new(coordinates).tap do |feature|
            feature.extend Candidate, ordering
            feature.knoll, feature.elevation = knoll, elevation
            feature["label"] = elevation.round
          end
        end
      end
    end

    def get_features
      selected, remaining = [], AVLTree.new
      spatial_index = RTree.load(candidates, &:bounds)
      buffer = @spacing * @map.scale / 1000.0

      candidates.each.with_index do |candidate, index|
        log_update "%s: examining candidates: %.1f%%" % [@name, 100.0 * index  / candidates.length]
        spatial_index.search(candidate.bounds(buffer)).each do |other|
          next if other == candidate
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

      GeoJSON::Collection.new @map.projection, selected
    end
  end
end

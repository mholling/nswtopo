module NSWTopo
  module GeoJSON
    class MultiLineString
      include StraightSkeleton

      def length
        @coordinates.sum(&:path_length)
      end

      def offset(*margins, **options)
        linestrings = margins.inject Nodes.new(@coordinates) do |nodes, margin|
          nodes.progress limit: margin, **options.slice(:rounding_angle, :cutoff_angle)
        end.readout
        MultiLineString.new linestrings, @properties
      end

      def buffer(*margins, **options)
        MultiLineString.new(@coordinates + @coordinates.map(&:reverse), @properties).offset(*margins, **options)
      end

      def smooth(margin, **options)
        linestrings = Nodes.new(@coordinates).tap do |nodes|
          nodes.progress **options.slice(:rounding_angle).merge(limit: margin)
          nodes.progress **options.slice(:rounding_angle, :cutoff_angle).merge(limit: -2 * margin)
          nodes.progress **options.slice(:rounding_angle, :cutoff_angle).merge(limit: margin)
        end.readout
        MultiLineString.new linestrings, @properties
      end

      def samples(interval)
        points = @coordinates.flat_map do |linestring|
          distance = linestring.path_length
          LineString.sample_at(linestring, interval) do |point, along, angle|
            [point, (2 * along - distance).abs - distance]
          end.entries
        end.sort_by(&:last).map(&:first)
        MultiPoint.new points, @properties
      end

      def dissolve_points
        MultiPoint.new @coordinates.flat_map(&:itself)
      end

      def subdivide(count)
        linestrings = @coordinates.flat_map do |coordinates|
          coordinates.each_cons(2).each_slice(count).map do |pairs|
            pairs.inject { |part, (p0, p1)| part << p1 }
          end
        end
        MultiLineString.new linestrings, @properties
      end
    end
  end
end

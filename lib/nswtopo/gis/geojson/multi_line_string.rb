module NSWTopo
  module GeoJSON
    class MultiLineString
      include StraightSkeleton

      def path_length
        explode.sum(&:path_length)
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
        points = explode.flat_map do |linestring|
          distance = linestring.path_length
          linestring.sample_at(interval) do |point, along, angle|
            [point, (2 * along - distance).abs - distance]
          end
        end.sort_by(&:last).map(&:first)
        MultiPoint.new points, @properties
      end

      def dissolve_points
        MultiPoint.new @coordinates.flat_map(&:itself)
      end

      def dissolve_segments
        explode.map(&:dissolve_segments).inject(&:+)
      end

      def subdivide(count)
        linestrings = @coordinates.flat_map do |linestring|
          linestring.each_cons(2).each_slice(count).map do |pairs|
            pairs.inject { |part, (p0, p1)| part << p1 }
          end
        end
        MultiLineString.new linestrings, @properties
      end

      def trim(amount)
        explode.map do |feature|
          feature.trim amount
        end.reject(&:empty?).sum(MultiLineString.new [])
      end

      def to_polygon
        Polygon.new @coordinates, @properties
      end

      def to_multipolygon
        polygons = explode.tap do |rings|
          rings.each(&:reverse!) if rings.first.interior?
        end.slice_when(&:exterior?).map do |rings|
          rings.map(&:coordinates)
        end
        MultiPolygon.new polygons, @properties
      end
    end
  end
end

module NSWTopo
  module GeoJSON
    class MultiLineString
      include StraightSkeleton

      def freeze!
        each { }
        freeze
      end

      def path_length
        sum(&:path_length)
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
        sampled = flat_map do |linestring|
          distance = linestring.path_length
          linestring.sample_at(interval) do |point, along, angle|
            [point, (2 * along - distance).abs - distance]
          end
        end.sort_by(&:last).map(&:first)
        MultiPoint.new sampled, @properties
      end

      def dissolve_points
        MultiPoint.new @coordinates.flatten(1), @properties
      end

      def subdivide(count)
        subdivided = flat_map do |linestring|
          linestring.each_cons(2).each_slice(count).map do |pairs|
            pairs.inject { |part, (p0, p1)| part << p1 }
          end
        end
        MultiLineString.new subdivided, @properties
      end

      def trim(amount)
        map do |feature|
          feature.trim amount
        end.reject(&:empty?).inject(empty_linestrings, &:+)
      end

      def to_polygon
        Polygon.new @coordinates, @properties
      end

      def to_multipolygon
        unclaimed, exterior_rings = partition(&:interior?)
        exterior_rings.sort_by(&:signed_area).map(&:to_polygon).map do |polygon|
          interior_rings, unclaimed = unclaimed.partition do |ring|
            polygon.contains? ring.first
          end
          interior_rings.inject(polygon, &:add_ring)
        end.inject(empty_polygons, &:+)
      end
    end
  end
end

module NSWTopo
  module GeoJSON
    class MultiPolygon
      include StraightSkeleton

      def freeze!
        each { }
        freeze
      end

      def rings
        MultiLineString.new @coordinates.flatten(1), @properties
      end

      def area
        rings.sum(&:signed_area)
      end

      def nodes
        Nodes.new rings
      end

      def skeleton
        segments = []
        nodes.progress do |event, node0, node1|
          segments << [node0.point.to_f, node1.point.to_f]
        end
        MultiLineString.new segments, @properties
      end

      def centres(fraction: 0.5, min_width: nil, interval:, lines: true)
        neighbours = Hash.new { |neighbours, node| neighbours[node] = [] }
        samples, tails, node1 = {}, {}, nil

        nodes.progress(interval: interval) do |event, *args|
          case event
          when :nodes
            node0, node1 = *args
            neighbours[node0] << node1
            neighbours[node1] << node0
          when :interval
            travel, rings = *args
            samples[travel] = rings.flat_map do |ring|
              LineString.new(ring).sample_at(interval)
            end
          end
        end

        samples[node1.travel] = [node1.point.to_f]
        max_travel = neighbours.keys.map(&:travel).max
        min_travel = [fraction * max_travel, min_width && 0.5 * min_width].compact.max

        features = samples.select do |travel, points|
          travel > min_travel
        end.map do |travel, points|
          MultiPoint.new points, @properties
        end.reverse
        return features unless lines

        loop do
          break unless neighbours.reject do |node, (neighbour, *others)|
            others.any? || neighbours[neighbour].one?
          end.each do |node, (neighbour, *)|
            next if neighbours[neighbour].one?
            neighbours.delete node
            neighbours[neighbour].delete node
            nodes, length = tails.delete(node) || [[node], 0]
            candidate = [nodes << neighbour, length + (node.point - neighbour.point).norm]
            tails[neighbour] = [tails[neighbour], candidate].compact.max_by(&:last)
          end.any?
        end

        lengths, lines, candidates = Hash.new(0), Hash.new, tails.values
        while candidates.any?
          (*nodes, node), length = candidates.pop
          next if (neighbours[node] - nodes).each do |neighbour|
            candidates << [[*nodes, node, neighbour], length + (node.point - neighbour.point).norm]
          end.any?
          index = nodes.find(&:index).index
          tail_nodes, tail_length = tails[node] || [[node], 0]
          lengths[index], lines[index] = length + tail_length, nodes + tail_nodes.reverse if length + tail_length > lengths[index]
        end

        linestrings = lines.values.flat_map do |nodes|
          nodes.chunk do |node|
            node.travel >= min_travel
          end.select(&:first).map(&:last).reject(&:one?).map do |nodes|
            nodes.map(&:point).map(&:to_f)
          end
        end
        features.prepend MultiLineString.new(linestrings, @properties)
      end

      def centrepoints(interval:, **options)
        centres(**options, interval: interval, lines: false)
      end

      def centrelines(**options)
        centres(**options, interval: nil, lines: true)
      end

      def buffer(*margins, **options)
        rings.offset(*margins.map(&:-@), **options).to_multipolygon
      end

      def centroids
        map(&:centroid).inject(empty_points, &:+)
      end

      def samples(interval)
        points = rings.flat_map do |coordinates|
          linestring.sample_at(interval)
        end
        MultiPoint.new points, @properties
      end

      def dissolve_points
        MultiPoint.new @coordinates.flatten(2), @properties
      end

      def remove_holes(&block)
        map do |polygon|
          polygon.remove_holes(&block)
        end.inject(empty_polygons, &:+)
      end
    end
  end
end

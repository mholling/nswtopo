module NSWTopo
  module GeoJSON
    class MultiPolygon
      include StraightSkeleton

      def clip(hull)
        polys = @coordinates.inject([]) do |result, rings|
          lefthanded = rings.first.clockwise?
          interior, exterior = hull.zip(hull.perps).inject(rings) do |rings, (vertex, perp)|
            insides, neighbours, clipped = Hash[].compare_by_identity, Hash[].compare_by_identity, []
            rings.each do |points|
              points.map do |point|
                point.minus(vertex).dot(perp) >= 0
              end.segments.zip(points.segments).each do |inside, segment|
                insides[segment] = inside
                neighbours[segment] = [nil, nil]
              end.map(&:last).ring.each do |segment0, segment1|
                neighbours[segment1][0], neighbours[segment0][1] = segment0, segment1
              end
            end
            neighbours.select! do |segment, _|
              insides[segment].any?
            end
            insides.select do |segment, inside|
              inside.inject(&:^)
            end.each do |segment, inside|
              segment[inside[0] ? 1 : 0] = segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
            end.sort_by do |segment, inside|
              segment[inside[0] ? 1 : 0].minus(vertex).cross(perp) * (lefthanded ? -1 : 1)
            end.map(&:first).each_slice(2) do |segment0, segment1|
              segment = [segment0[1], segment1[0]]
              neighbours[segment0][1] = neighbours[segment1][0] = segment
              neighbours[segment] = [segment0, segment1]
            end
            while neighbours.any?
              segment, * = neighbours.first
              clipped << []
              while neighbours.include? segment
                clipped.last << segment[0]
                *, segment = neighbours.delete(segment)
              end
              clipped.last << clipped.last.first
            end
            clipped
          end.partition(&:clockwise?).rotate(lefthanded ? 1 : 0)
          next result << exterior + interior if exterior.one?
          exterior.inject(result) do |result, exterior_ring|
            within, interior = interior.partition do |interior_ring|
              interior_ring.first.within? exterior_ring
            end
            result << [exterior_ring, *within]
          end
        end
        polys.none? ? nil : polys.one? ? Polygon.new(*polys, @properties) : MultiPolygon.new(polys, @properties)
      end

      def area
        @coordinates.flatten(1).sum(&:signed_area)
      end

      def skeleton
        segments = []
        Nodes.new(@coordinates.flatten(1)).progress do |event, node0, node1|
          segments << [node0.point, node1.point].to_f
        end
        MultiLineString.new segments, @properties
      end

      def centres(fraction: 0.5, min_width: nil, interval:, lines: true)
        neighbours = Hash.new { |neighbours, node| neighbours[node] = [] }
        samples, tails, node1 = {}, {}, nil

        Nodes.new(@coordinates.flatten(1)).progress(interval: interval) do |event, *args|
          case event
          when :nodes
            node0, node1 = *args
            neighbours[node0] << node1
            neighbours[node1] << node0
          when :interval
            travel, rings = *args
            samples[travel] = rings.flat_map do |ring|
              ring.sample_at interval
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
            candidate = [nodes << neighbour, length + [node.point, neighbour.point].distance]
            tails[neighbour] = [tails[neighbour], candidate].compact.max_by(&:last)
          end.any?
        end

        lengths, lines, candidates = Hash.new(0), Hash.new, tails.values
        while candidates.any?
          (*nodes, node), length = candidates.pop
          next if (neighbours[node] - nodes).each do |neighbour|
            candidates << [[*nodes, node, neighbour], length + [node.point, neighbour.point].distance]
          end.any?
          index = nodes.find(&:index).index
          tail_nodes, tail_length = tails[node] || [[node], 0]
          lengths[index], lines[index] = length + tail_length, nodes + tail_nodes.reverse if length + tail_length > lengths[index]
        end

        linestrings = lines.values.map do |nodes|
          nodes.chunk do |node|
            node.travel >= min_travel
          end.select(&:first).map(&:last).reject(&:one?).map do |nodes|
            nodes.map(&:point).to_f
          end
        end.flatten(1)
        features.prepend MultiLineString.new(linestrings, @properties)
      end

      def centrepoints(interval:, **options)
        centres(**options, interval: interval, lines: false)
      end

      def centrelines(**options)
        centres(**options, interval: nil, lines: true)
      end

      def buffer(*margins, **options)
        nodes = Nodes.new @coordinates.flatten(1)
        margins.each do |margin|
          nodes.progress limit: -margin, **options.slice(:rounding_angle, :cutoff_angle)
        end
        interior_rings, exterior_rings = nodes.readout.partition(&:hole?)
        polygons, foo = exterior_rings.sort_by(&:signed_area).inject [[], interior_rings] do |(polygons, interior_rings), exterior_ring|
          claimed, unclaimed = interior_rings.partition do |interior_ring|
            interior_ring.first.within? exterior_ring
          end
          [polygons << [exterior_ring, *claimed], unclaimed]
        end
        MultiPolygon.new polygons.entries, @properties
      end

      def centroids
        MultiPoint.new @coordinates.map(&:first).map(&:centroid), @properties
      end

      def samples(interval)
        points = @coordinates.flatten(1).flat_map do |ring|
          ring.sample_at interval
        end
        MultiPoint.new points, @properties
      end
    end
  end
end

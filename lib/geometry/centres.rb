module Centres
  include StraightSkeleton

  def centres(dimensions, *args, options)
    fraction  = args[0] || options["fraction"] || 0.5
    min_width = args[1] || options["min-width"]
    interval  = args[2] || options["interval"]
    neighbours = Hash.new { |neighbours, node| neighbours[node] = [] }
    samples, tails, node1 = Hash.new, Hash.new, nil
    Nodes.new(self).progress(nil, "interval" => interval) do |event, *args|
      case event
      when :nodes
        node0, node1 = *args
        neighbours[node0] << node1
        neighbours[node1] << node0
      when :interval
        travel, points = *args
        samples[travel] = points
      end
    end
    samples[node1.travel] = [ node1.point.to_f ]
    max_travel = neighbours.keys.map(&:travel).max
    min_travel = [ fraction * max_travel, min_width && 0.5 * min_width ].compact.max
    dimensions.map do |dimension|
      data = case dimension
      when 0
        samples.select do |travel, points|
          travel > min_travel
        end.map(&:last).flatten(1).reverse
      when 1
        loop do
          break unless neighbours.reject do |node, (neighbour, *others)|
            others.any? || neighbours[neighbour].one?
          end.each do |node, (neighbour, *)|
            next if neighbours[neighbour].one?
            neighbours.delete node
            neighbours[neighbour].delete node
            nodes, length = tails.delete(node) || [ [ node ], 0 ]
            candidate = [ nodes << neighbour, length + [ node.point, neighbour.point ].distance ]
            tails[neighbour] = [ tails[neighbour], candidate ].compact.max_by(&:last)
          end.any?
        end
        lengths, lines, candidates = Hash.new(0), Hash.new, tails.values
        while candidates.any?
          (*nodes, node), length = candidates.pop
          next if (neighbours[node] - nodes).each do |neighbour|
            candidates << [ [ *nodes, node, neighbour ], length + [ node.point, neighbour.point ].distance ]
          end.any?
          index = nodes.find(&:index).index
          tail_nodes, tail_length = tails[node] || [ [ node ], 0 ]
          lengths[index], lines[index] = length + tail_length, nodes + tail_nodes.reverse if length + tail_length > lengths[index]
        end
        lines.values.map do |nodes|
          nodes.chunk do |node|
            node.travel >= min_travel
          end.select(&:first).map(&:last).reject(&:one?).map do |nodes|
            nodes.map(&:point).to_f
          end
        end.flatten(1)
      end
      [ dimension, data ]
    end
  end
end

Array.send :include, Centres

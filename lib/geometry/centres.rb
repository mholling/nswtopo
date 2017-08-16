module Centres
  include StraightSkeleton

  def centres(dimensions, *args, options)
    fraction  = args[0] || options["fraction"]
    min_width = args[1] || options["min-width"]
    neighbours = Hash.new { |neighbours, node| neighbours[node] = [] }
    incoming, tails = Hash.new(0), Hash.new
    Nodes.new(self, true).progress do |node0, node1|
      incoming[node1] += 1
      neighbours[node0] << node1
      neighbours[node1] << node0
    end
    max_travel = neighbours.keys.map(&:travel).max
    min_travel = [ (fraction || 0.5) * max_travel, min_width && 0.5 * min_width ].compact.max
    dimensions.map do |dimension|
      data = case dimension
      when 0
        points = incoming.select do |node, count|
          node.travel >= min_travel
        end.sort_by do |node, count|
          [ -count, -node.travel ]
        end.map(&:first).map(&:point).to_f
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
        lengths, lines = Hash.new(0), Hash.new
        areas, candidates = map(&:signed_area), tails.values
        while candidates.any?
          (*nodes, node), length = candidates.pop
          next if (neighbours[node] - nodes).each do |neighbour|
            candidates << [ [ *nodes, node, neighbour ], length + [ node.point, neighbour.point ].distance ]
          end.any?
          index = nodes.map(&:whence).inject(node.whence, &:|).find do |index|
            areas[index] > 0
          end
          tail_nodes, tail_length = tails[node] || [ [ node ], 0 ]
          lengths[index], lines[index] = length + tail_length, nodes + tail_nodes.reverse if length + tail_length > lengths[index]
        end
        lines.values.map do |nodes|
          nodes.chunk do |node|
            node.travel >= min_travel
          end.select(&:first).map(&:last).reject(&:one?).map do |nodes|
            nodes.map(&:point).to_f
          end
        end.flatten(1).sanitise(false)
      end
      [ dimension, data ]
    end
  end
end

Array.send :include, Centres

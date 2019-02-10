module StraightSkeleton
  DEFAULT_ROUNDING_ANGLE = 15

  class Nodes
    def self.stitch(normal, *edge)
      edge[1].neighbours[0], edge[0].neighbours[1] = edge
      edge[1].normals[0] = edge[0].normals[1] = normal
    end

    def initialize(data)
      @active, @indices = Set[], Hash.new.compare_by_identity
      data.to_d.map do |points|
        next points unless points.length > 2
        points.inject [] do |points, point|
          points.last == point ? points : points << point
        end
      end.map.with_index do |(*points, point), index|
        points.first == point ? [points, :ring, (index unless points.hole?)] : [points << point, :segments, nil]
      end.each do |points, pair, index|
        normals = points.send(pair).map(&:difference).map(&:normalised).map(&:perp)
        points.map do |point|
          Vertex.new self, point
        end.each do |node|
          @active << node
        end.send(pair).zip(normals).each do |edge, normal|
          Nodes.stitch normal, *edge
          @indices[normal] = index if index
        end
      end
    end

    # #################################
    # solve for vector p and scalar t:
    #   n0.p - t = x0
    #   n1.p - t = x1
    #   n2.p - t = x2
    # #################################

    def self.solve(n0, n1, n2, x0, x1, x2)
      det = n2.cross(n1) + n1.cross(n0) + n0.cross(n2)
      return if det.zero?
      travel = (x0 * n1.cross(n2) + x1 * n2.cross(n0) + x2 * n0.cross(n1)) / det
      point = [n1.minus(n2).perp.times(x0), n2.minus(n0).perp.times(x1), n0.minus(n1).perp.times(x2)].inject(&:plus) / det
      [point, travel]
    end

    # #################################
    # solve for vector p and scalar t:
    #   n0.p - t = x0
    #   n1.p - t = x1
    #   n2 x p   = x2
    # #################################

    def self.solve_asym(n0, n1, n2, x0, x1, x2)
      det = n0.minus(n1).dot(n2)
      return if det.zero?
      travel = (x0 * n1.dot(n2) - x1 * n2.dot(n0) + x2 * n0.cross(n1)) / det
      point = (n2.times(x0 - x1).plus n0.minus(n1).perp.times(x2)) / det
      [point, travel]
    end

    def collapse(edge)
      (n00, n01), (n10, n11) = edge.map(&:normals)
      p0, p1 = edge.map(&:point)
      t0, t1 = edge.map(&:travel)
      return if p0.equal? p1
      good = [n00 && !n00.cross(n01).zero?, n11 && !n11.cross(n10).zero?]
      point, travel = case
      when good.all? then Nodes::solve(n00, n01, n11, n00.dot(p0) - t0, n01.dot(p1) - t1, n11.dot(p1) - t1)
      when good[0] then Nodes::solve_asym(n00, n01, n10, n00.dot(p0) - t0, n01.dot(p0) - t0, n10.cross(p1))
      when good[1] then Nodes::solve_asym(n11, n10, n10, n11.dot(p1) - t1, n10.dot(p1) - t1, n01.cross(p0))
      end || return
      return if travel * direction < @travel * direction
      return if @limit && travel.abs > @limit.abs
      @candidates << Collapse.new(self, point, travel, edge)
    end

    def split(node)
      bounds = node.project(@limit).zip(node.point).map do |centre, coord|
        [coord, centre - @limit, centre + @limit].minmax
      end if @limit
      @index.search(bounds).map do |edge|
        p0, p1, p2 = [*edge, node].map(&:point)
        t0, t1, t2 = [*edge, node].map(&:travel)
        (n00, n01), (n10, n11), (n20, n21) = [*edge, node].map(&:normals)
        next if p0 == p2 || p1 == p2
        next if node.terminal? and Split === node and node.source.normals[0].equal? n01
        next if node.terminal? and Split === node and node.source.normals[1].equal? n01
        next unless node.terminal? || [n20, n21].compact.inject(&:plus).dot(n01) < 0
        point, travel = case
        when n20 && n21 then Nodes::solve(n20, n21, n01, n20.dot(p2) - t2, n21.dot(p2) - t2, n01.dot(p0) - t0)
        when n20 then Nodes::solve_asym(n01, n20, n20, n01.dot(p0) - t0, n20.dot(p2) - t2, n20.cross(p2))
        when n21 then Nodes::solve_asym(n01, n21, n21, n01.dot(p0) - t0, n21.dot(p2) - t2, n21.cross(p2))
        end || next
        next if travel * @direction < node.travel
        next if @limit && travel.abs > @limit.abs
        next if point.minus(p0).dot(n01) * @direction < 0
        Split.new self, point, travel, node, edge[0]
      end.compact.each do |split|
        @candidates << split
      end
    end

    def include?(node)
      @active.include? node
    end

    def insert(node)
      @active << node
      @track[node.normals[1]] << node if node.normals[1]
      2.times.inject [node] do |nodes|
        [nodes.first.prev, *nodes, nodes.last.next].compact
      end.segments.uniq.each do |edge|
        collapse edge
      end
      split node if node.splits?
    end

    def track(normal)
      @track[normal].select(&:active?).map do |node|
        [node, node.next]
      end
    end

    def nodeset
      [].tap do |result|
        pending, processed = @active.dup, Set[]
        while pending.any?
          nodes = pending.take 1
          while node = nodes.last.next and !processed.include?(node)
            nodes.push node
            processed << node
          end
          while node = nodes.first.prev and !processed.include?(node)
            nodes.unshift node
            processed << node
          end
          pending.subtract nodes
          nodes << nodes.first if nodes.first == nodes.last.next
          result << nodes
        end
      end
    end

    attr_reader :direction

    def progress(limit: nil, rounding_angle: DEFAULT_ROUNDING_ANGLE, cutoff_angle: nil, interval: nil, splits: true, &block)
      return self if limit && limit.zero?

      nodeset.tap do
        @active.clear
        @indices = nil
      end.map do |*nodes, node|
        nodes.first == node ? [nodes, :ring] : [nodes << node, :segments]
      end.each.with_index do |(nodes, pair), index|
        normals = nodes.send(pair).map do |edge|
          edge[0].normals[1]
        end
        nodes.map do |node|
          Vertex.new self, node.project(@limit)
        end.each do |node|
          @active << node
        end.send(pair).zip(normals).each do |edge, normal|
          Nodes.stitch normal, *edge
        end
      end if @limit

      @candidates, @travel, @limit, @direction = AVLTree.new, 0, limit && limit.to_d, limit ? limit <=> 0 : 1

      rounding_angle *= Math::PI / 180
      cutoff_angle *= Math::PI / 180 if cutoff_angle

      @track = Hash.new do |hash, normal|
        hash[normal] = Set[]
      end.compare_by_identity

      @active.group_by(&:point).reject do |point, nodes|
        case nodes.length
        when 1 then true
        when 2
          nodes[0].next&.point == nodes[1].prev&.point &&
          nodes[1].next&.point == nodes[0].prev&.point
        else false
        end
      end.each do |point, nodes|
        @active.subtract nodes
        nodes.inject [] do |events, node|
          events << [:incoming, node.prev] if node.prev
          events << [:outgoing, node.next] if node.next
          events
        end.sort_by do |event, node|
          case event
          when :incoming then [-@direction * node.normals[1].angle,        1]
          when :outgoing then [-@direction * node.normals[0].negate.angle, 0]
          end
        end.ring.map(&:transpose).each do |events, neighbours|
          node = Vertex.new self, point
          case events
          when [:outgoing, :incoming] then next
          when [:outgoing, :outgoing]
            Nodes.stitch neighbours[1].normals[0], node, neighbours[1]
          when [:incoming, :incoming]
            Nodes.stitch neighbours[0].normals[1], neighbours[0], node
          when [:incoming, :outgoing]
            Nodes.stitch neighbours[0].normals[1], neighbours[0], node
            Nodes.stitch neighbours[1].normals[0], node, neighbours[1]
          end
          @active << node
        end
      end

      @active.reject(&:terminal?).select do |node|
        direction * Math::atan2(node.normals.inject(&:cross), node.normals.inject(&:dot)) < -cutoff_angle
      end.each do |node|
        @active.delete node
        2.times.map do
          Vertex.new self, node.point
        end.each.with_index do |vertex, index|
          vertex.normals[index] = node.normals[index]
          vertex.neighbours[index] = node.neighbours[index]
          vertex.neighbours[index].neighbours[1-index] = vertex
          @active << vertex
        end
      end if cutoff_angle

      @active.reject(&:terminal?).select(&:reflex?).each do |node|
        angle = Math::atan2 node.normals.inject(&:cross).abs, node.normals.inject(&:dot)
        extras = (angle / rounding_angle).floor
        next unless extras > 0
        extra_normals = extras.times.map do |n|
          node.normals[0].rotate_by(angle * (n + 1) * -direction / (extras + 1))
        end.each do |normal|
          @indices[normal] = @indices[node.normals[0]] if @indices
        end
        extra_nodes = extras.times.map do
          Vertex.new self, node.point
        end.each do |extra_node|
          @active << extra_node
        end
        edges = [node.neighbours[0], node, *extra_nodes, node.neighbours[1]].segments
        normals = [node.normals[0], *extra_normals, node.normals[1]]
        edges.zip(normals).each do |edge, normal|
          Nodes.stitch normal, *edge
        end
      end

      @active.select(&:next).map do |node|
        [node, node.next]
      end.each do |edge|
        collapse edge
        @track[edge[0].normals[1]] << edge[0]
      end.map do |edge|
        [edge.map(&:point).transpose.map(&:minmax), edge]
      end.tap do |bounds_edges|
        @index = RTree.load bounds_edges
      end

      @active.select(&:splits?).each do |node|
        split node
      end if splits

      travel = 0
      while candidate = @candidates.pop
        next unless candidate.viable?
        @travel = candidate.travel
        while travel < @travel
          yield :interval, travel, readout(travel)
          travel += interval
        end if interval && block_given?
        candidate.replace! do |node, index = 0|
          @active.delete node
          yield :nodes, *[node, candidate].rotate(index).map(&:original) if block_given?
        end
      end

      self
    end

    def readout(travel = @limit)
      nodeset.map do |nodes|
        nodes.map do |node|
          node.project(travel).to_f
        end
      end.map do |points|
        points.segments.reject do |segment|
          segment.inject(&:==)
        end.map(&:last).unshift(points.first)
      end.reject(&:one?)
    end

    def index(node)
      @indices.values_at(*node.normals).find(&:itself)
    end
  end
end

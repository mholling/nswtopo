module StraightSkeleton
  DEFAULT_ROUNDING_ANGLE = 15

  module Node
    attr_reader :point, :travel, :neighbours, :normals, :whence, :original

    def active?
      @nodes.include? self
    end

    def terminal?
      @neighbours.one?
    end

    def reflex?
      normals.inject(&:cross) * @nodes.direction <= 0
    end

    def splits?
      terminal? || reflex?
    end

    def prev
      @neighbours[0]
    end

    def next
      @neighbours[1]
    end

    # ###########################################
    # solve for vector p:
    #   n0.(p - @point) = travel - @travel
    #   n1.(p - @point) = travel - @travel
    # ###########################################

    def project(travel)
      det = normals.inject(&:cross) if normals.all?
      case
      when det && det.nonzero?
        x = normals.map { |normal| travel - @travel + normal.dot(point) }
        [ normals[1][1] * x[0] - normals[0][1] * x[1], normals[0][0] * x[1] - normals[1][0] * x[0] ] / det
      when normals[0] then normals[0].times(travel - @travel).plus(point)
      when normals[1] then normals[1].times(travel - @travel).plus(point)
      end
    end
  end

  module InteriorNode
    include Node

    def <=>(other)
      (@travel <=> other.travel) * @nodes.direction
    end

    def insert!
      @normals = @neighbours.map.with_index do |neighbour, index|
        neighbour.neighbours[1-index] = self if neighbour
        neighbour.normals[1-index] if neighbour
      end
      @nodes.insert self
    end
  end

  class Collapse
    include InteriorNode

    def initialize(nodes, point, travel, sources)
      @original, @nodes, @point, @travel, @sources = self, nodes, point, travel, sources
      @whence = @sources.map(&:whence).inject(&:|)
    end

    def viable?
      @sources.all?(&:active?)
    end

    def replace!(&block)
      @neighbours = [ @sources[0].prev, @sources[1].next ]
      @neighbours.inject(&:==) ? block.call(prev) : insert! if @neighbours.any?
      @sources.each(&block)
    end

    alias splits? terminal?
  end

  class Split
    include InteriorNode

    def initialize(nodes, point, travel, source, node)
      @original, @nodes, @point, @travel, @source, @normal = self, nodes, point, travel, source, node.normals[1]
      @whence = source.whence | node.whence
    end

    attr_reader :source

    def viable?
      return false unless @source.active?
      @edge = @nodes.track(@normal).find do |edge|
        (n00, n01), (n10, n11) = edge.map(&:normals)
        p0, p1 = edge.map(&:point)
        next if point.minus(p0).cross(n00 ? n00.plus(n01) : n01) < 0
        next if point.minus(p1).cross(n11 ? n11.plus(n10) : n10) > 0
        true
      end
    end

    def split!(index, &block)
      @neighbours = [ @source.neighbours[index], @edge[1-index] ].rotate index
      @neighbours.inject(&:equal?) ? block.call(prev, prev.is_a?(Collapse) ? 1 : 0) : insert! if @neighbours.any?
    end

    def replace!(&block)
      dup.split!(0, &block)
      dup.split!(1, &block)
      block.call @source
    end
  end

  class Vertex
    include Node

    def initialize(nodes, point, normals, whence)
      @original, @neighbours, @nodes, @point, @normals, @whence, @travel = self, [ nil, nil ], nodes, point, normals, whence, 0
    end
  end

  class Nodes
    def initialize(data, closed)
      @closed, @active = closed, Set[]
      data.sanitise(closed).to_d.each.with_index do |points, index|
        normals = (closed ? points.ring : points.segments).map(&:difference).map(&:normalised).map(&:perp)
        normals = closed ? normals.ring.rotate(-1) : normals.unshift(nil).push(nil).segments
        points.zip(normals).map do |point, normals|
          Vertex.new self, point, normals, Set[index]
        end.each do |node|
          @active << node
        end.send(closed ? :ring : :segments).each do |edge|
          edge[1].neighbours[0], edge[0].neighbours[1] = edge
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
      point = [ n1.minus(n2).perp.times(x0), n2.minus(n0).perp.times(x1), n0.minus(n1).perp.times(x2) ].inject(&:plus) / det
      [ point, travel ]
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
      [ point, travel ]
    end

    def collapse(edge)
      (n00, n01), (n10, n11) = edge.map(&:normals)
      p0, p1 = edge.map(&:point)
      t0, t1 = edge.map(&:travel)
      return if p0.equal? p1
      good = [ n00 && !n00.cross(n01).zero?, n11 && !n11.cross(n10).zero? ]
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
        [ coord, centre - @limit, centre + @limit ].minmax
      end if @limit
      @index.search(bounds).map do |edge|
        p0, p1, p2 = [ *edge, node ].map(&:point)
        t0, t1, t2 = [ *edge, node ].map(&:travel)
        (n00, n01), (n10, n11), (n20, n21) = [ *edge, node ].map(&:normals)
        next if p0 == p2 || p1 == p2
        next if node.terminal? and Split === node and node.source.normals[0].equal? n01
        next if node.terminal? and Split === node and node.source.normals[1].equal? n01
        next unless node.terminal? || [ n20, n21 ].compact.inject(&:plus).dot(n01) < 0
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
      2.times.inject [ node ] do |nodes|
        [ nodes.first.prev, *nodes, nodes.last.next ].compact
      end.segments.uniq.each do |edge|
        collapse edge
      end
      split node if node.splits?
    end

    def track(normal)
      @track[normal].select(&:active?).map do |node|
        [ node, node.next ]
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
          result << nodes
        end
      end
    end

    attr_reader :direction

    def progress(limit, options = {}, &block)
      return self if limit && limit.zero?
      nodeset.tap do
        @active.clear
      end.each.with_index do |nodes, index|
        nodes.map do |node|
          Vertex.new self, node.project(@limit), node.normals, Set[index]
        end.each do |node|
          @active << node
        end.send(@closed ? :ring : :segments).each do |edge|
          edge[1].neighbours[0], edge[0].neighbours[1] = edge
        end
      end if @limit

      @candidates, @travel, @limit, @direction = AVLTree.new, 0, limit && limit.to_d, limit ? limit <=> 0 : 1

      interval, rounding_angle, cutoff_angle = options.values_at "interval", "rounding-angle", "cutoff"
      rounding_angle = (rounding_angle || DEFAULT_ROUNDING_ANGLE) * Math::PI / 180
      cutoff_angle *= Math::PI / 180 if cutoff_angle

      @track = Hash.new do |hash, normal|
        hash[normal] = Set[]
      end.compare_by_identity

      joins = Set[]
      @active.group_by(&:point).each do |point, nodes|
        nodes.permutation(2).select do |node0, node1|
          node0.prev && node1.next && node0.prev.point != node1.next.point
        end.group_by(&:first).map(&:last).map do |pairs|
          pairs.min_by do |node0, node1|
            normals = [ node1.normals[1], node0.normals[0] ]
            Math::atan2 normals.inject(&:cross), normals.inject(&:dot)
          end
        end.each do |node0, node1|
          @candidates << Split.new(self, point, 0, node0, node1)
          joins << node0 << node1
        end
        # nodes produce here won't be rounded, but this will be very rare
      end

      @active.reject(&:terminal?).select do |node|
        direction * Math::atan2(node.normals.inject(&:cross), node.normals.inject(&:dot)) < -cutoff_angle
      end.each do |node|
        @active.delete node
        2.times.map do
          Vertex.new self, node.point, [ nil, nil ], node.whence
        end.each.with_index do |vertex, index|
          vertex.normals[index] = node.normals[index]
          vertex.neighbours[index] = node.neighbours[index]
          vertex.neighbours[index].neighbours[1-index] = vertex
          @active << vertex
        end
      end if cutoff_angle

      (@active - joins).reject(&:terminal?).select(&:reflex?).each do |node|
        angle = Math::atan2 node.normals.inject(&:cross).abs, node.normals.inject(&:dot)
        extras = (angle / rounding_angle).floor
        next unless extras > 0
        normals = extras.times.map do |n|
          node.normals[0].rotate_by(angle * (n + 1) * -direction / (extras + 1))
        end
        nodes = extras.times.map do
          Vertex.new self, node.point, [ nil, nil ], node.whence
        end.each do |extra_node|
          @active << extra_node
        end.unshift(node)
        [ node.neighbours[0], *nodes, node.neighbours[1] ].segments.each do |edge|
          edge[1].neighbours[0], edge[0].neighbours[1] = edge
        end.zip([ node.normals[0], *normals, node.normals[1] ]).each do |edge, normal|
          edge[1].normals[0] = edge[0].normals[1] = normal
        end
      end

      @active.select(&:next).map do |node|
        [ node, node.next ]
      end.each do |edge|
        collapse edge
        @track[edge[0].normals[1]] << edge[0]
      end.map do |edge|
        [ edge.map(&:point).transpose.map(&:minmax), edge ]
      end.tap do |bounds_edges|
        @index = RTree.load bounds_edges
      end

      @active.select(&:splits?).each do |node|
        split node
      end if options.fetch("splits", true)

      travel = 0
      while candidate = @candidates.pop
        next unless candidate.viable?
        @travel = candidate.travel
        while travel < @travel
          yield :interval, travel, readout(travel).sample_at(@closed, interval)
          travel += interval
        end if interval && block_given?
        candidate.replace! do |node, index = 0|
          @active.delete node
          yield :nodes, *[ node, candidate ].rotate(index).map(&:original) if block_given?
        end
      end

      self
    end

    def readout(travel = @limit)
      nodeset.map do |nodes|
        nodes.map do |node|
          node.project(travel).to_f
        end
      end.sanitise(@closed)
    end
  end
end

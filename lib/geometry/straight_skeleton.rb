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
    
    def prev
      @neighbours[0]
    end
    
    def next
      @neighbours[1]
    end
    
    def heading
      @heading ||= case
      when terminal?
        normals.compact.first
      when normals.inject(&:dot) >= 0
        normals.inject(&:plus).normalised
      when normals.inject(&:cross) >= 0
        normals.map(&:perp).inject(&:minus).normalised
      else
        normals.map(&:perp).inject(&:minus).normalised.negate
      end
    end
    
    def project(travel)
      cosine = terminal? ? 1 : Math::sqrt((1 + normals.inject(&:dot)) * 0.5)
      heading.times((travel - @travel) / cosine).plus(point)
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
  end
  
  module InteriorNode
    include Node
    
    def <=>(other)
      @travel <=> other.travel
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
  end
  
  class Split
    include InteriorNode
    
    def initialize(nodes, point, travel, source, node)
      @original, @nodes, @point, @travel, @source, @normal = self, nodes, point, travel, source, node.normals[1]
      @whence = source.whence | node.whence
    end
    
    def viable?
      return false unless @source.active?
      @edge = @nodes.track(@normal).find do |edge|
        (n00, n01), (n10, n11) = edge.map(&:normals)
        p0, p1 = edge.map(&:point)
        next if (n00 ? point.minus(p0).cross(n00) : 0) + point.minus(p0).cross(n01) < 0
        next if (n11 ? point.minus(p1).cross(n11) : 0) + point.minus(p1).cross(n10) > 0
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
    
    def initialize(nodes, point, index, normals)
      @original, @neighbours, @nodes, @whence, @point, @normals, @travel = self, [ nil, nil ], nodes, Set[index], point, normals, 0
    end
    
    def reflex?
      normals.inject(&:cross) < 0 || normals.inject(&:plus).all?(&:zero?)
    end
    
    def split(edge, limit)
      p0, p1, p2 = [ *edge, self ].map(&:point)
      (n00, n01), (n10, n11), (n20, n21) = [ *edge, self ].map(&:normals)
      return if p0 == p2 || p1 == p2
      # return unless (n20 ? n20.dot(n01) : 0) + (n21 ? n21.dot(n01) : 0) < 0
      return unless heading.dot(n01) < 0
      point, travel = case
      when n20 && n21 then Node::solve(n20, n21, n01, n20.dot(p2), n21.dot(p2), n01.dot(p0))
      when n20 then Node::solve_asym(n01, n20, n20, n01.dot(p0), n20.dot(p2), n20.cross(p2))
      when n21 then Node::solve_asym(n01, n21, n21, n01.dot(p0), n21.dot(p2), n21.cross(p2))
      end
      return if !travel || travel < 0 || travel.infinite? || (limit && travel >= limit)
      return if point.minus(p0).dot(n01) < 0
      Split.new @nodes, point, travel, self, edge[0]
    end
  end
  
  class Nodes
    def initialize(data, closed, limit = nil, options = {})
      @candidates, @closed, @limit = AVLTree.new, closed, limit
      @track = Hash.new do |hash, normal|
        hash[normal] = []
      end.compare_by_identity
      rounding = options.fetch("rounding", true)
      rounding_angle = options.fetch("rounding-angle", DEFAULT_ROUNDING_ANGLE) * Math::PI / 180
      cutoff = options["cutoff"] && options["cutoff"] * Math::PI / 180
      nodes = data.sanitise(closed).tap do |lines|
        @repeats = lines.flatten(1).group_by { |point| point }.reject { |point, points| points.one? }
      end.map.with_index do |points, index|
        normals = (closed ? points.ring : points.segments).map(&:difference).map(&:normalised).map(&:perp)
        normals = closed ? normals.ring.rotate(-1) : normals.unshift(nil).push(nil).segments
        points.zip(normals).map do |point, normals|
          vertex = Vertex.new(self, point, index, normals)
          next vertex if normals.one?
          next vertex unless rounding && vertex.reflex?
          angle = Math::atan2 normals.inject(&:cross), normals.inject(&:dot)
          angle -= 2 * Math::PI if angle > 0
          extras = cutoff && angle.abs > cutoff ? 1 : (angle.abs / rounding_angle).floor
          extras.times.inject(normals.take(1)) do |normals, n|
            normals << normals[0].rotate_by(angle * (n + 1) / (extras + 1))
          end.push(normals.last).segments.map do |normals|
            Vertex.new self, point, index, normals
          end
        end.flatten
      end
      nodes.map(&closed ? :ring : :segments).each do |edges|
        edges.each do |edge|
          edge[1].neighbours[0], edge[0].neighbours[1] = edge
        end.each do |edge|
          collapse edge
        end.map(&:first).each do |node|
          @track[node.normals[1]] << node
        end
      end
      @active = nodes.flatten.to_set
    end
    
    def collapse(edge)
      (n00, n01), (n10, n11) = edge.map(&:normals)
      p0, p1 = edge.map(&:point)
      t0, t1 = edge.map(&:travel)
      return if p0.equal? p1
      good = [ n00 && !n00.cross(n01).zero?, n11 && !n11.cross(n10).zero? ]
      point, travel = case
      when good.all? then Node::solve(n00, n01, n11, n00.dot(p0) - t0, n01.dot(p1) - t1, n11.dot(p1) - t1)
      when good[0] then Node::solve_asym(n00, n01, n10, n00.dot(p0) - t0, n01.dot(p0) - t0, n10.cross(p1))
      when good[1] then Node::solve_asym(n11, n10, n10, n11.dot(p1) - t1, n10.dot(p1) - t1, n01.cross(p0))
      end
      return if !travel || travel <= 0 || (@limit && travel >= @limit)
      return if travel < t0 || travel < t1
      @candidates << Collapse.new(self, point, travel, edge)
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
    end
    
    def edges
      @active.select(&:next).map do |node|
        [ node, node.next ]
      end
    end
    
    def track(normal)
      @track[normal].select(&:active?).map do |node|
        [ node, node.next ]
      end
    end
    
    def progress(options = {}, &block)
      if options.fetch("splits", true)
        repeated_terminals, repeated_nodes = @active.select do |node|
          @repeats.include? node.point
        end.partition(&:terminal?)
        repeated_terminals.group_by(&:point).each do |point, nodes|
          nodes.permutation(2).select do |node1, node2|
            node1.prev && node2.next
          end.select do |pair|
            pair.map(&:heading).inject(&:cross) > 0
          end.group_by(&:first).map(&:last).map do |pairs|
            pairs.min_by do |pair|
              pair.map(&:heading).inject(&:dot)
            end
          end.compact.each do |node1, node2|
            @candidates << Split.new(self, point, 0, node1, node2)
          end
        end
        repeated_nodes.group_by(&:point).select do |point, nodes|
          nodes.all?(&:reflex?)
        end.each do |point, nodes|
          nodes.inject([]) do |(*sets, set), node|
            case
            when !set then                   [ [ node ] ]
            when set.last.next == node  then [ *sets, [ *set, node ] ]
            when set.first == node.next then [ *sets, [ node, *set ] ]
            else                             [ *sets,  set, [ node ] ]
            end
          end.sort_by do |set|
            set.first.heading.angle
          end.ring.each do |set0, set1|
            @candidates << Split.new(self, point, 0, set0.first, set1.last)
          end
        end if @closed
        index = RTree.load(edges) do |edge|
          edge.map(&:point).transpose.map(&:minmax)
        end if @limit
        @active.select do |node|
          node.terminal? || node.reflex?
        end.each do |node|
          bounds = node.project(@limit).zip(node.point).map do |centre, coord|
            [ coord, centre - @limit, centre + @limit ].minmax
          end if @limit
          (index ? index.search(bounds) : edges).map do |edge|
            node.split edge, @limit
          end.compact.each do |split|
            @candidates << split
          end
        end
      end
      while candidate = @candidates.pop
        next unless candidate.viable?
        candidate.replace! do |node, index = 0|
          @active.delete node
          yield [ node, candidate ].rotate(index).map(&:original) if block_given?
        end
      end
      self
    end
    
    def finalise
      Enumerator.new do |yielder|
        while @active.any?
          nodes = [ @active.first ]
          while node = nodes.last.next and node != nodes.first
            nodes.push node
          end
          while node = nodes.first.prev and node != nodes.last
            nodes.unshift node
          end
          nodes.each do |node|
            @active.delete node
          end.map do |node|
            node.project(@limit)
          end.tap do |points|
            yielder << points
          end
        end
      end.to_a.sanitise(@closed)
    end
    
    def project(&block)
      @active.map do |node|
        [ node.point, node.project(@limit) ]
      end.each(&block) if @limit
    end
  end
  
  def straight_skeleton(closed, limit = nil, options)
    return map(&:reverse).straight_skeleton(closed, -limit, options) if limit && limit < 0
    result = [ ]
    Nodes.new(self, closed, limit, options).progress do |nodes|
      result << nodes.map(&:point)
    end.project do |segment|
      result << segment
    end
    result
  end
  
  def centres(dimensions, *args, options)
    fraction  = args[0] || options["fraction"]
    min_width = args[1] || options["min-width"]
    points = map(&:centroid) if dimensions.include?(0) && all?(&:convex?)
    return [ [ 0, points ] ] if points && dimensions == [ 0 ]
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
        points ||= incoming.select do |node, count|
          count > 2 && node.travel >= min_travel
        end.keys.sort_by(&:travel).reverse.map(&:point)
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
            nodes.map(&:point)
          end
        end.flatten(1).sanitise(false)
      end
      [ dimension, data ]
    end
  end
  
  def inset(closed, margin, options = {})
    return self if margin.zero?
    Nodes.new(self, closed, margin, options).progress(options).finalise
  end
  
  def outset(closed, margin, options = {})
    return self if margin.zero?
    map(&:reverse).inset(closed, margin, options).map(&:reverse)
  end
  
  def buffer(closed, margin, overshoot = margin)
    case
    when !closed
      (self + map(&:reverse)).inset(closed, margin + overshoot).outset(closed, overshoot, "splits" => false)
    when margin > 0
      outset(closed, margin + overshoot).inset(closed, overshoot, "splits" => false)
    else
      inset(closed, -(margin + overshoot)).outset(closed, -overshoot, "splits" => false)
    end
  end
  
  def smooth(closed, margin, cutoff = nil)
    inset(closed, margin).outset(closed, 2 * margin, "cutoff" => cutoff).inset(closed, margin, "cutoff" => cutoff)
  end
end

Array.send :include, StraightSkeleton

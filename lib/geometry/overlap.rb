module Overlap
  def separated_by?(buffer)
    simplex = [ map(&:first).inject(&:minus) ]
    search = simplex[0].negate
    loop do
      return false unless simplex[0].dot(search.normalised).abs > buffer
      max = self[0].max_by { |point| point.dot search }
      min = self[1].min_by { |point| point.dot search }
      support = max.minus min
      return true unless simplex[0].minus(support).dot(search) < 0
      rays = simplex.map { |point| point.minus support }
      case simplex.length
      when 1
        case
        when rays[0].dot(support) > 0
          simplex, search = [ support ], support.negate
        when rays[0].cross(support) < 0
          simplex, search = [ support, *simplex ], rays[0].perp
        else
          simplex, search = [ *simplex, support ], rays[0].perp.negate
        end
      when 2
        case
        when rays[0].cross(support) > 0 && rays[0].perp.cross(support) > 0
          simplex, search = [ simplex[0], support ], rays[0].perp.negate
        when rays[1].cross(support) < 0 && rays[1].perp.cross(support) > 0
          simplex, search = [ support, simplex[1] ], rays[1].perp
        when rays[0].cross(support) <= 0 && rays[1].cross(support) >= 0
          return false
        else
          simplex, search = [ support ], support.negate
        end
      end
    end
  end
  
  def overlap?(buffer = 0)
    !separated_by?(buffer)
  end
  
  def overlaps(buffer = 0)
    return [] if empty?
    axis = flatten(1).transpose.map { |values| values.max - values.min }.map.with_index.max.last
    events, tops, bots, results = AVLTree.new, [], [], []
    margin = [ buffer, 0 ]
    each.with_index do |hull, index|
      min, max = hull.map { |point| point.rotate axis }.minmax
      events << [ min.minus(margin), index, :start ]
      events << [ max.plus( margin), index, :stop  ]
    end
    events.each do |point, index, event|
      top, bot = at(index).transpose[1-axis].minmax
      case event
      when :start
        not_above = bots.select { |bot, other| bot >= top - buffer }.map(&:last)
        not_below = tops.select { |top, other| top <= bot + buffer }.map(&:last)
        (not_below & not_above).reject do |other|
          values_at(index, other).separated_by? buffer
        end.each do |other|
          results << [ index, other ]
        end
        tops << [ top, index ]
        bots << [ bot, index ]
      when :stop
        tops.delete [ top, index ]
        bots.delete [ bot, index ]
      end
    end
    results
  end
end

Array.send :include, Overlap

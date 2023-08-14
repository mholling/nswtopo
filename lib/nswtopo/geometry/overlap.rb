module Overlap
  def separated_by?(buffer)
    simplex = [map(&:first).inject(&:-)]
    perp = simplex[0].perp
    loop do
      return false unless case
      when simplex.one? then simplex[0].norm
      when simplex.inject(&:-).dot(simplex[1]) > 0 then simplex[1].norm
      when simplex.inject(&:-).dot(simplex[0]) < 0 then simplex[0].norm
      else simplex.inject(&:cross).abs / simplex.inject(&:-).norm
      end > buffer
      max = self[0].max_by { |point| perp.cross point }
      min = self[1].min_by { |point| perp.cross point }
      support = max - min
      return true unless (simplex[0] - support).cross(perp) > 0
      rays = simplex.map { |point| point - support }
      case simplex.length
      when 1
        case
        when rays[0].dot(support) > 0
          simplex, perp = [support], support.perp
        when rays[0].cross(support) < 0
          simplex, perp = [support, *simplex], rays[0]
        else
          simplex, perp = [*simplex, support], -rays[0]
        end
      when 2
        case
        when rays[0].cross(support) > 0 && rays[0].dot(support) < 0
          simplex, perp = [simplex[0], support], -rays[0]
        when rays[1].cross(support) < 0 && rays[1].dot(support) < 0
          simplex, perp = [support, simplex[1]], rays[1]
        when rays[0].cross(support) <= 0 && rays[1].cross(support) >= 0
          return false
        else
          simplex, perp = [support], support.perp
        end
      end
    end
  end

  def overlap?(buffer)
    !separated_by?(buffer)
  end
end

Array.send :include, Overlap

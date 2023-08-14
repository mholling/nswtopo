module StraightSkeleton
  module Node
    attr_reader :point, :travel, :neighbours, :normals, :original

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

    def index
      @index ||= @nodes.index self
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
        (normals[0].perp * x[1] - normals[1].perp * x[0]) / det
      when normals[0] then normals[0] * (travel - @travel) + point
      when normals[1] then normals[1] * (travel - @travel) + point
      end
    end
  end
end

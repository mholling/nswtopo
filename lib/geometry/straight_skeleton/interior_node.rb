module StraightSkeleton
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
end

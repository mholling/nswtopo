module StraightSkeleton
  class Vertex
    include Node

    def initialize(nodes, point)
      @original, @nodes, @point, @neighbours, @normals, @travel = self, nodes, point, [nil, nil], [nil, nil], 0
    end
  end
end

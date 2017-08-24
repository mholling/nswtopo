module NSWTopo
  class DeclinationSource
    include VectorRenderer

    PARAMS = %q[
      spacing: 1000
      arrows: 150
      stroke: darkred
      stroke-width: 0.1
      fill: darkred
      symbol:
        path:
          d: M 0 0 L 0.4 2 L 0 1.3 L -0.4 2 Z
          stroke: none
    ]

    def initialize(name, params)
      @name, @params = name, YAML.load(PARAMS).merge(params)
    end

    def features
      arrows = params["arrows"]
      bl, br, tr, tl = CONFIG.map.coord_corners
      width, height = CONFIG.map.extents
      margin = height * Math::tan((CONFIG.map.rotation + CONFIG.map.declination) * Math::PI / 180.0)
      spacing = params["spacing"] / Math::cos((CONFIG.map.rotation + CONFIG.map.declination) * Math::PI / 180.0)
      lines = [ [ bl, br ], [ tl, tr ] ].map.with_index do |edge, index|
        [ [ 0, 0 - margin ].min, [ width, width - margin ].max ].map do |extension|
          edge.along (extension + margin * index) / width
        end
      end.map do |edge|
        (edge.distance / spacing).ceil.times.map do |n|
          edge.along(n * spacing / edge.distance)
        end
      end.transpose.map do |line|
        CONFIG.map.coords_to_mm line
      end.clip_lines(CONFIG.map.mm_corners)
      return [ [ 1, lines, nil, "lines"] ] unless arrows
      markers = lines.map.with_index do |points, index|
        start = index.even? ? 0.25 : 0.75
        (points.distance / arrows - start).ceil.times.map do |n|
          points.along (start + n) * arrows / points.distance
        end
      end.flatten(1)
      [ [ 1, lines, "lines" ], [ 0, markers, "markers", nil, CONFIG.map.declination ] ]
    rescue ServerError => e
      raise BadLayerError.new(e.message)
    end
  end
end

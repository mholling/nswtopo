module NSWTopo
  module GeoJSON
    class Polygon
      include SVG

      delegate %i[area skeleton centres centrepoints centrelines buffer samples] => :multi
      delegate %i[dissolve_segments] => :rings

      def validate!
        map do |coordinates|
          LineString.new coordinates
        end.inject(false) do |hole, ring|
          ring.reverse! if hole ^ ring.hole?
          true
        end
      end

      def bounds
        @coordinates.first.transpose.map(&:minmax)
      end

      def wkt
        @coordinates.map do |ring|
          ring.map do |point|
            point.join(" ")
          end.join(", ").prepend("(").concat(")")
        end.join(", ").prepend("POLYGON (").concat(")")
      end

      def centroid
        @coordinates.flat_map do |ring|
          ring.each_cons(2).map do |p0, p1|
            next (p0 + p1) * p0.cross(p1), 3 * p0.cross(p1)
          end
        end.transpose.then do |centroids_x6, signed_areas_x6|
          point = centroids_x6.inject(&:+) / signed_areas_x6.inject(&:+)
          Point.new point, @properties
        end
      end

      def rings
        MultiLineString.new @coordinates, @properties
      end

      def surrounds?(geometry)
        # implementation for simple convex polygons only
        geometry.dissolve_points.all? do |point|
          point.within? @coordinates.first
        end
      end

      def svg_path_data
        rings.explode.map(&:svg_path_data).each.with_object("Z").entries.join(?\s)
      end
    end
  end
end

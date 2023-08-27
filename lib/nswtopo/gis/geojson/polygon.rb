module NSWTopo
  module GeoJSON
    class Polygon
      include SVG

      delegate %i[area skeleton centres centrepoints centrelines buffer samples] => :multi
      delegate %i[dissolve_segments] => :rings

      def validate!
        inject(false) do |hole, ring|
          ring.reverse! if hole ^ LineString.new(ring).interior?
          true
        end
      end

      def bounds
        first.transpose.map(&:minmax)
      end

      def wkt
        map do |ring|
          ring.map do |point|
            point.join(" ")
          end.join(", ").prepend("(").concat(")")
        end.join(", ").prepend("POLYGON (").concat(")")
      end

      def centroid
        flat_map do |ring|
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

      def add_ring(ring)
        Polygon.new [*@coordinates, ring.coordinates], @properties
      end

      def contains?(geometry)
        geometry = Point.new(geometry) if Vector === geometry
        geometry.dissolve_points.coordinates.all? do |point|
          sum do |ring|
            ring.each_cons(2).inject(0) do |winding, (p0, p1)|
              case
              when p1.y  > point.y && p0.y <= point.y && (p0 - p1).cross(p0 - point) >= 0 then winding + 1
              when p0.y  > point.y && p1.y <= point.y && (p1 - p0).cross(p0 - point) >= 0 then winding - 1
              when p0.y == point.y && p1.y == point.y && p0.x >= point.x && p1.x < point.x then winding + 1
              when p0.y == point.y && p1.y == point.y && p1.x >= point.x && p0.x < point.x then winding - 1
              else winding
              end
            end
          end.nonzero?
        end
      end

      def svg_path_data
        rings.map(&:svg_path_data).each.with_object("Z").entries.join(?\s)
      end
    end
  end
end

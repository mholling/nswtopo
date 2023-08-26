module NSWTopo
  module Labels
    class ConvexHulls < GeoJSON::MultiLineString
      def initialize(feature, buffer)
        @coordinates = case feature
        when GeoJSON::Polygon then feature.rings
        when GeoJSON::MultiPolygon then feature.rings
        else feature
        end.explode.flat_map do |feature|
          case feature
          when GeoJSON::Point # a point feature barrier
            x, y = *feature
            [[Vector[x-buffer, y-buffer], Vector[x+buffer, y-buffer], Vector[x+buffer, y+buffer], Vector[x-buffer, y+buffer]]]
          when GeoJSON::LineString # a linestring label to be broken down into segment hulls
            offsets = feature.each_cons(2).map do |p0, p1|
              (p1 - p0).perp.normalised * buffer
            end
            corners = offsets.then do |offsets|
              feature.closed? ? [offsets.last, *offsets, offsets.first] : [offsets.first, *offsets, offsets.last]
            end.each_cons(2).map do |o01, o12|
              next if o12.cross(o01) == 0
              (o01 + o12).normalised * buffer * (o12.cross(o01) <=> 0)
            end.each_cons(2)
            feature.each_cons(2).zip(corners, offsets).map do |(p0, p1), (c0, c1), offset|
              if c0 then [p0 + offset, p0 + c0, p0 - offset] else [p0 + offset, p0 - offset] end +
              if c1 then [p1 - offset, p1 + c1, p1 + offset] else [p1 - offset, p1 + offset] end
            end
          end
        end
        @properties = { source: self }
      end

      def svg_path_data
        explode.map(&:svg_path_data).each.with_object("Z").entries.join(" ")
      end

      def self.overlap?(*rings, buffer: 0)
        # implements Gilbert–Johnson–Keerthi
        simplex = [rings.map(&:first).inject(&:-)]
        perp = simplex[0].perp
        loop do
          return true unless case
          when simplex.one? then simplex[0].norm
          when simplex.inject(&:-).dot(simplex[1]) > 0 then simplex[1].norm
          when simplex.inject(&:-).dot(simplex[0]) < 0 then simplex[0].norm
          else simplex.inject(&:cross).abs / simplex.inject(&:-).norm
          end > buffer
          max = rings[0].max_by { |point| perp.cross point }
          min = rings[1].min_by { |point| perp.cross point }
          support = max - min
          return false unless (simplex[0] - support).cross(perp) > 0
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
              return true
            else
              simplex, perp = [support], support.perp
            end
          end
        end
      end
    end
  end
end

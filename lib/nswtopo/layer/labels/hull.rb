module NSWTopo
  module Labels
    class Hull < GeoJSON::LineString
      def initialize(feature, buffer, owner: nil)
        ring = case feature
        when GeoJSON::LineString # a single segment from a linestring
          p0, p1 = *feature
          offset = (p1 - p0).perp.normalised * buffer
          super [p0 - offset, p1 - offset, p1 + offset, p0 + offset, p0 - offset]
        when GeoJSON::Point # a point feature barrier
          x, y = *feature
          super [[x-buffer, y-buffer], [x+buffer, y-buffer], [x+buffer, y+buffer], [x-buffer, y+buffer], [x-buffer, y-buffer]]
        when GeoJSON::MultiLineString # collection of segments from a linestring
          offsets = feature.map do |p0, p1|
            (p1 - p0).perp.normalised * buffer
          end
          corners = offsets.each_cons(2).map do |d01, d12|
            (d01 + d12).normalised * (buffer * (d12.cross(d01) <=> 0))
          end
          feature.zip(offsets, corners).each.with_object [] do |((p0, p1), offset, corner), buffered|
            buffered << p0 + offset << p0 - offset << p1 + offset << p1 - offset
            buffered << p1 + corner if corner
          end.then do |points|
            GeoJSON::MultiPoint.new(points).convex_hull.coordinates
          end.then do |ring|
            super ring + ring.take(1)
          end
        end
        @owner = owner
      end

      attr_accessor :owner

      def overlaps?(other, buffer: 0)
        # implements Gilbert–Johnson–Keerthi
        rings = [self, other]
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

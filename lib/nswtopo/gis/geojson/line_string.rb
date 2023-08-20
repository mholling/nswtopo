module NSWTopo
  module GeoJSON
    class LineString
      def self.sample_at(coordinates, interval, offset: 0, &block)
        Enumerator.new do |yielder|
          alpha = (0.5 + Float(offset || 0) / interval) % 1.0
          coordinates.each_cons(2).inject [alpha, 0] do |(alpha, along), (p0, p1)|
            angle = (p1 - p0).angle
            loop do
              distance = (p1 - p0).norm
              fraction = alpha * interval / distance
              break unless fraction < 1
              p0 = p1 * fraction + p0 * (1 - fraction)
              along += alpha * interval
              yielder << (block_given? ? yield(p0, along, angle) : p0)
              alpha = 1.0
            end
            distance = (p1 - p0).norm
            next alpha - distance / interval, along + distance
          end
        end.entries
      end

      delegate %i[length offset buffer smooth samples subdivide] => :multi
      delegate %i[reverse!] => :@coordinates

      def bounds
        @coordinates.transpose.map(&:minmax)
      end

      def path_length
        each_cons(2).sum { |v0, v1| (v1 - v0).norm }
      end

      def closed?
        @coordinates.last == @coordinates.first
      end

      def signed_area
        each_cons(2).sum { |v0, v1| v0.cross(v1) } / 2
      end

      def clockwise?
        signed_area < 0
      end
      alias hole? clockwise?

      def anticlockwise?
        signed_area >= 0
      end

      def dissolve_segments
        MultiLineString.new each_cons(2).entries, @properties
      end

      def simplify(tolerance)
        chunks, simplified = [@coordinates], []
        while chunk = chunks.pop
          direction = (chunk.last - chunk.first).normalised
          delta, index = chunk.map do |point|
            (point - chunk.first).cross(direction).abs
          end.each.with_index.max_by(&:first)
          if delta < tolerance
            simplified.prepend chunk.first
          else
            chunks << chunk[0..index] << chunk[index..-1]
          end
        end
        simplified << @coordinates.last
        LineString.new simplified, @properties
      end

      def sample_at(interval, **opts, &block)
        LineString.sample_at(@coordinates, interval, **opts, &block)
      end

      def segmentise(interval)
        LineString.new sample_at(interval).entries.push(@coordinates.last), @properties
      end

      def smooth_window(window)
        [@coordinates.take(1)*(window-1), @coordinates, @coordinates.last(1)*(window-1)].flatten(1).each_cons(window).map do |points|
          points.inject(&:+) / window
        end.then do |smoothed|
          LineString.new smoothed, @properties
        end
      end

      def trim(amount)
        return self unless amount > 0
        ending, total = path_length - amount, 0
        trimmed = @coordinates.each_cons(2).with_object [] do |(p0, p1), trimmed|
          delta = (p1 - p0).norm
          case
          when total >= ending then break trimmed
          when total <= amount - delta
          when total <= amount
            trimmed << (p0 * (delta + total - amount) + p1 * (amount - total)) / delta
            trimmed << (p0 * (delta + total - ending) + p1 * (ending - total)) / delta if total + delta >= ending
          else
            trimmed << p0
            trimmed << (p0 * (delta + total - ending) + p1 * (ending - total)) / delta if total + delta >= ending
          end
          total += delta
        end
        LineString.new trimmed, @properties
      end

      def crop(length)
        trim((path_length - length) / 2)
      end

      def convex_overlaps?(other, buffer:)
        # implements Gilbert–Johnson–Keerthi; for rings defining convex polygons only
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

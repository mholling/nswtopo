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
        end
      end

      delegate %i[length offset buffer smooth samples] => :multi

      def bounds
        @coordinates.transpose.map(&:minmax)
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
    end
  end
end

module VectorSequences
  def in_sections(count)
    map(&:segments).map do |segments|
      segments.each_slice(count).map do |segments|
        segments.inject do |section, segment|
          section << segment[1]
        end
      end
    end.flatten(1)
  end

  # TODO: use keyword arguments for extra
  def sample_at(interval, extra = nil)
    map do |sequence|
      sequence.periodically(interval, extra).to_a
    end.inject([], &:+)
  end

  def sample_outwards(interval)
    map(&:path_length).zip(self).map do |distance, line|
      line.periodically(interval, :along).map do |point, along|
        [point, (2 * along - distance).abs - distance]
      end
    end.inject([], &:+).sort_by(&:last).map(&:first)
  end
end

Array.send :include, VectorSequences

module VectorSequences
  def sample_at(interval, **options)
    map do |sequence|
      sequence.periodically(interval, **options).to_a
    end.inject([], &:+)
  end

  def sample_outwards(interval)
    map(&:path_length).zip(self).map do |distance, line|
      line.periodically(interval, along: true).map do |point, along|
        [point, (2 * along - distance).abs - distance]
      end
    end.inject([], &:+).sort_by(&:last).map(&:first)
  end
end

Array.send :include, VectorSequences

module VectorSequences
  def sample_at(interval, **options)
    map do |sequence|
      sequence.periodically(interval, **options).to_a
    end.flatten(1)
  end
end

Array.send :include, VectorSequences

module InParallel
  CORES = Etc.nprocessors rescue 1

  def in_parallel(&block)
    inject [] do |threads, element|
      while threads.length == CORES
        sleep 1
        threads, finished = threads.partition(&:alive?)
        finished.each(&:join)
      end
      threads << Thread.new(element, &block)
    end.each(&:join)
    self
  end

  def in_parallel_groups(&block)
    group_by.with_index do |item, index|
      index % CORES
    end.values.each.in_parallel(&block)
  end
end

Enumerator.send :include, InParallel

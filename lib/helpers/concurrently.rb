module Concurrently
  CORES = Etc.nprocessors rescue 1

  def concurrently(threads = CORES, &block)
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

  def concurrent_groups(threads = CORES, &block)
    group_by.with_index do |item, index|
      index % threads
    end.values.each.concurrently(&block)
  end
end

Enumerator.send :include, Concurrently

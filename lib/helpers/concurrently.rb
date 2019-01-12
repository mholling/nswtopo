module Concurrently
  CORES = Etc.nprocessors rescue 1

  def concurrently(threads = CORES, &block)
    elements = Queue.new
    threads.times.map do
      Thread.new do
        while element = elements.pop
          block.call element
        end
      end
    end.tap do
      inject(elements, &:<<).close
    end.each(&:join)
    self
  end

  def concurrent_groups(threads = CORES, &block)
    group_by.with_index do |item, index|
      index % threads
    end.values.map do |items|
      Thread.new(items, &block)
    end.each(&:join)
  end
end

Enumerator.send :include, Concurrently

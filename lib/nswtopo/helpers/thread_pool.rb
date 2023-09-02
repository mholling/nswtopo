class ThreadPool
  CORES = Etc.nprocessors rescue 1

  def initialize(size = CORES)
    @args, @size = [], size
  end

  def <<(args)
    tap { @args << args }
  end

  def threads(queue, &block)
    @size.times.map do
      Thread.new do
        while args = queue.pop
          block.call(*args)
        end
      end
    end
  end

  def each(&block)
    queue = Queue.new
    threads(queue, &block).tap do
      @args.inject(queue, &:<<).close
    end.each(&:join)
    @args
  end

  def in_groups(&block)
    queue = Queue.new
    threads(queue, &block).tap do
      @args.group_by.with_index do |args, index|
        index % @size
      end.values.inject(queue, &:<<).close
    end.each(&:join)
    @args
  end
end

require_relative 'helpers/thread_pool'
require_relative 'helpers/colour'

module Helpers
  refine Dir.singleton_class do
    def mktmppath
      mktmpdir("nswtopo_") do |path|
        yield Pathname.new(path)
      end
    end
  end

  refine Hash do
    def deep_merge(other)
      merge(other) do |key, old_value, new_value|
        Hash === old_value && Hash === new_value ? old_value.deep_merge(new_value) : new_value
      end
    end
  end

  refine Array do
    # partially partition element range in-place, according to block, returning the partitioned ranges
    def partition!(range, &block)
      return range.begin...range.begin, range if range.one?
      last, pivot = range.end - 1, Kernel.rand(range)
      self[pivot], self[last] = self[last], self[pivot]
      pivot_value = block.call(at last)
      index = range.inject(range.begin) do |store, index|
        next store unless index == last || block.call(at index) < pivot_value
        self[index], self[store] = self[store], self[index]
        store + 1
      end
      return range.begin...index, index...range.end
    end

    def median_partition!(range = 0...length, &block)
      median, target = (range.begin + range.end) / 2, range
      while target.begin != median
        lower, upper = partition!(target, &block)
        target = lower === median ? lower : upper
      end
      return range.begin...median, median...range.end
    end
  end
end

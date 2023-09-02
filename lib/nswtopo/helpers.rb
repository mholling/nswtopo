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
end

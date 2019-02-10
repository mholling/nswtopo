module HashHelpers
  def deep_merge(other)
    merge(other) do |key, old_value, new_value|
      Hash === old_value ? Hash === new_value ? old_value.deep_merge(new_value) : new_value : new_value
    end
  end

  def deep_merge!(other)
    merge!(other) do |key, old_value, new_value|
      Hash === old_value ? Hash === new_value ? old_value.deep_merge!(new_value) : new_value : new_value
    end
  end
end

Hash.send :include, HashHelpers

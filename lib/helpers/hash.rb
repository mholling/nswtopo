module HashHelpers
  def deep_merge(other)
    merge(other) do |key, old_value, new_value|
      Hash === old_value ? Hash == new_value ? old_value.deep_merge(new_value) : new_value : new_value
    end
  end

  def deep_merge!(other)
    merge!(other) do |key, old_value, new_value|
      Hash === old_value ? Hash == new_value ? old_value.deep_merge!(new_value) : new_value : new_value
    end
  end

  def to_query
    # URI.escape reject { |key, value| value.nil? }.map { |key, value| "#{key}=#{value}" }.join(?&)
    # TODO: remove eventually
    URI.encode_www_form self
  end
end

Hash.send :include, HashHelpers

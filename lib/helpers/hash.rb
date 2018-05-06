module HashHelpers
  def deep_merge(hash)
    hash.inject(self.dup) do |result, (key, value)|
      result.merge(key => result[key].is_a?(Hash) && value.is_a?(Hash) ? result[key].deep_merge(value) : value)
    end
  end
  
  def deep_merge!(hash)
    hash.each do |key, value|
      self[key].is_a?(Hash) && value.is_a?(Hash) ? self[key].deep_merge!(value) : self[key] = value
    end
    self
  end

  def to_query
    URI.escape reject { |key, value| value.nil? }.map { |key, value| "#{key}=#{value}" }.join(?&)
  end
end

Hash.send :include, HashHelpers

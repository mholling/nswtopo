class REXML::Element
  alias_method :unadorned_add_element, :add_element
  def add_element(name, attrs = {})
    unadorned_add_element(name, attrs).tap do |element|
      yield element if block_given?
    end
  end
end

module REXML::Functions
  def self.ends_with(string, test)
    string(string).rindex(string(test)) == string(string).length - string(test).length
  end
end

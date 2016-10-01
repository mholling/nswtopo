class REXML::Element # TODO: get rid of this...
  alias_method :unadorned_add_element, :add_element
  def add_element(name, attrs = {})
    unadorned_add_element(name, attrs).tap do |element|
      yield element if block_given?
    end
  end
end

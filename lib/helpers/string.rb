module StringHelpers
  def to_category
    gsub(/^\W+|\W+$/, '').gsub(/\W+/, ?-)
  end
end

String.send :include, StringHelpers

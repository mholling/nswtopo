module StringHelpers
  def to_category
    tr('^_a-zA-Z0-9', ?-).squeeze(?-).delete_prefix(?-).delete_suffix(?-)
  end
end

String.send :include, StringHelpers

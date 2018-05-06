module StringHelpers
  def in_two
    return split ?\n if match ?\n
    slash = split ?/
    return [ slash[0] + ?/, slash[1] ].map(&:strip) if slash.length == 2
    words = split ?\s
    (1...words.length).map do |index|
      [ words[0 ... index].join(?\s), words[index ... words.length].join(?\s) ]
    end.min_by do |lines|
      lines.map(&:length).max
    end || [ dup ]
  end
  
  def to_category
    gsub(/^\W+|\W+$/, '').gsub(/\W+/, ?-)
  end
end

String.send :include, StringHelpers

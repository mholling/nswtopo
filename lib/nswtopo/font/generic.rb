module NSWTopo
  module Font
    module Generic
      WIDTHS = {
        ?A => 0.732, ?B => 0.678, ?C => 0.682, ?D => 0.740, ?E => 0.583, ?F => 0.558, ?G => 0.728, ?H => 0.761, ?I => 0.256, ?J => 0.331, ?K => 0.641, ?L => 0.542, ?M => 0.843,
        ?N => 0.740, ?O => 0.769, ?P => 0.649, ?Q => 0.769, ?R => 0.690, ?S => 0.620, ?T => 0.599, ?U => 0.728, ?V => 0.695, ?W => 1.108, ?X => 0.649, ?Y => 0.637, ?Z => 0.591,
        ?a => 0.595, ?b => 0.595, ?c => 0.492, ?d => 0.595, ?e => 0.542, ?f => 0.335, ?g => 0.599, ?h => 0.583, ?i => 0.236, ?j => 0.289, ?k => 0.521, ?l => 0.236, ?m => 0.876,
        ?n => 0.583, ?o => 0.571, ?p => 0.595, ?q => 0.595, ?r => 0.360, ?s => 0.492, ?t => 0.347, ?u => 0.575, ?v => 0.529, ?w => 0.864, ?x => 0.533, ?y => 0.529, ?z => 0.513,
        ?0 => 0.595, ?1 => 0.595, ?2 => 0.595, ?3 => 0.595, ?4 => 0.595, ?5 => 0.595, ?6 => 0.595, ?7 => 0.595, ?8 => 0.595, ?9 => 0.595, ?! => 0.227, ?" => 0.422, ?# => 0.604,
        ?$ => 0.595, ?% => 0.934, ?& => 0.678, ?' => 0.219, ?( => 0.314, ?) => 0.314, ?* => 0.451, ?+ => 0.595, ?, => 0.227, ?- => 0.426, ?. => 0.227, ?/ => 0.331, ?\\ => 0.327,
        ?[ => 0.314, ?] => 0.314, ?^ => 0.595, ?_ => 0.500, ?` => 0.310, ?: => 0.227, ?; => 0.227, ?< => 0.595, ?= => 0.595, ?> => 0.595, ?? => 0.442, ?@ => 0.930, ?\s => 0.265,
      }
      WIDTHS.default = WIDTHS[?M]

      def glyph_length(string, attributes)
        font_size, letter_spacing, word_spacing = attributes.values_at("font-size", "letter-spacing", "word-spacing").map(&:to_f)
        string.chars.each_cons(2).inject(WIDTHS[string[0]] * font_size) do |sum, pair|
          next sum + WIDTHS[pair[1]] * font_size + letter_spacing                unless pair[0] == ?\s
          next sum + WIDTHS[pair[1]] * font_size + letter_spacing + word_spacing unless pair[1] == ?\s
          sum
        end
      end
    end
  end
end

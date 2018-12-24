module NSWTopo
  module Font
    ATTRIBUTES = %w[font-family font-variant font-style font-weight font-size letter-spacing word-spacing]
    # TODO: fall back to generic when Chrome::Error occurs

    def self.configure
      extend CONFIG["chrome"] ? defined?(PTY) ? Chrome : Generic : Generic
    end

    def self.in_two(string, attributes)
      words = string.split(string[?\n] || string[?/] || ?\s).map(&:strip)
      (1...words.size).map do |index|
        [ words[0...index].join(?\s), words[index...words.size].join(?\s) ]
      end.map do |lines|
        lines.map do |line|
          [ line, glyph_length(line, attributes) ]
        end
      end.min_by do |lines_widths|
        lines_widths.map(&:last).max
      end || [ [ words[0], glyph_length(words[0], attributes) ] ]
    end

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

    module Chrome
      Error = Class.new RuntimeError

      def command(string)
        @input.puts string
        lines, match = @output.expect(/(\{.*)\n/, 1)
        response = JSON.parse match
        raise Error, response.dig("exceptionDetails", "exception", "description") if response["exceptionDetails"]
        response.fetch("result").dig("value")
      rescue TypeError, JSON::ParserError, KeyError
        raise Error, "unexpected Chrome error"
      end

      def start_chrome
        chrome = CONFIG["chrome"]
        svg = <<~EOF
          <?xml version='1.0' encoding='UTF-8'?>
          <svg version='1.1' baseProfile='full' xmlns='http://www.w3.org/2000/svg' width='1mm' height='1mm' viewBox='0 0 1 1'>
            <rect id='mm' width='1' height='1' stroke='none' />
            <text id='text' />
          </svg>
        EOF
        @output, @input, @pid = PTY.spawn %Q["#{chrome}" --headless --repl "data:image/svg+xml;base64,#{Base64.encode64 svg}"]
        ObjectSpace.define_finalizer self, Proc.new { @input.puts "quit" }
        command %Q[text = document.getElementById("text")]
        @mm = command %Q[document.getElementById("mm").getBoundingClientRect().width]
      end

      def self.extended(instance)
        instance.start_chrome
      end

      def validate(family)
        return unless family
        @families ||= Set[]
        @families.add?(family) || return
        command %Q[text.textContent="abcdefghijklmnopqrstuvwxyz"]
        [ "font-family:#{family}", nil ].map do |style|
          command %Q[text.setAttribute("style", "#{style}")]
          command %Q[text.getBoundingClientRect().width]
        end.inject(&:==) || return
        puts "Warning: font '#{family}' doesn't appear to be present"
      end

      def glyph_length(string, attributes)
        style = ATTRIBUTES.zip(attributes.values_at *ATTRIBUTES).select(&:last).map do |pair|
          pair.join ?:
        end.join(?;)
        style << ";white-space:pre" if ?\s == string
        validate attributes["font-family"]
        command %Q[text.setAttribute("style", #{style.inspect})]
        command %Q[text.textContent=#{string.inspect}]
        command(%Q[text.getBoundingClientRect().width]) / @mm
      end
    end
  end
end

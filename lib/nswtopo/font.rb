module NSWTopo
  class Font
    ChromeError = Class.new Exception
    ATTRIBUTES = %w[font-family font-variant font-style font-weight]
    GENERIC_WIDTHS = {
      ?A => 0.732, ?B => 0.678, ?C => 0.682, ?D => 0.740, ?E => 0.583, ?F => 0.558, ?G => 0.728, ?H => 0.761, ?I => 0.256, ?J => 0.331, ?K => 0.641, ?L => 0.542, ?M => 0.843,
      ?N => 0.740, ?O => 0.769, ?P => 0.649, ?Q => 0.769, ?R => 0.690, ?S => 0.620, ?T => 0.599, ?U => 0.728, ?V => 0.695, ?W => 1.108, ?X => 0.649, ?Y => 0.637, ?Z => 0.591,
      ?a => 0.595, ?b => 0.595, ?c => 0.492, ?d => 0.595, ?e => 0.542, ?f => 0.335, ?g => 0.599, ?h => 0.583, ?i => 0.236, ?j => 0.289, ?k => 0.521, ?l => 0.236, ?m => 0.876,
      ?n => 0.583, ?o => 0.571, ?p => 0.595, ?q => 0.595, ?r => 0.360, ?s => 0.492, ?t => 0.347, ?u => 0.575, ?v => 0.529, ?w => 0.864, ?x => 0.533, ?y => 0.529, ?z => 0.513,
      ?0 => 0.595, ?1 => 0.595, ?2 => 0.595, ?3 => 0.595, ?4 => 0.595, ?5 => 0.595, ?6 => 0.595, ?7 => 0.595, ?8 => 0.595, ?9 => 0.595, ?! => 0.227, ?" => 0.422, ?# => 0.604,
      ?$ => 0.595, ?% => 0.934, ?& => 0.678, ?' => 0.219, ?( => 0.314, ?) => 0.314, ?* => 0.451, ?+ => 0.595, ?, => 0.227, ?- => 0.426, ?. => 0.227, ?/ => 0.331, ?\\ => 0.327,
      ?[ => 0.314, ?] => 0.314, ?^ => 0.595, ?_ => 0.500, ?` => 0.310, ?: => 0.227, ?; => 0.227, ?< => 0.595, ?= => 0.595, ?> => 0.595, ?? => 0.442, ?@ => 0.930, ?\s => 0.265,
    }
    GLYPHS = GENERIC_WIDTHS.keys

    def self.[](attributes)
      attributes = ATTRIBUTES.zip(attributes.values_at *ATTRIBUTES).select(&:last).to_h
      @fonts ||= {}
      @fonts[attributes] ||= new(attributes)
    end

    def self.warnings
      @fonts.select do |attributes, font|
        font.missing
      end.keys.group_by do |attributes|
        attributes["font-family"]
      end.keys.each do |family|
        puts "Warning: font '#{family}' doesn't appear to be present"
      end
      puts "Warning: couldn't get font metrics from Chrome; generic values used" if @fonts.values.any?(&:generic)
    end

    attr_reader :missing, :generic

    def initialize(attributes)
      chrome = CONFIG["chrome"] || CONFIG["chromium"]
      Dir.mktmppath do |temp_dir|
        xml = REXML::Document.new
        xml << REXML::XMLDecl.new(1.0, "utf-8")
        svg = xml.add_element "svg", "version" => 1.1, "baseProfile" => "full", "xmlns" => "http://www.w3.org/2000/svg"
        svg.add_element "rect", "width" => "1mm", "height" => "1mm", "id" => "scale", "stroke" => "none"
        svg.add_element "text", attributes.merge("font-size" => "1mm", "style" => "white-space: pre", "id" => "text")
        svg_path = temp_dir + "glyphs.svg"
        svg_path.write xml
        PTY.spawn %Q["#{chrome}" --headless --enable-logging --log-level=1 --repl "file://#{svg_path}"] do |output, input, pid|
          command = lambda do |text|
            input.puts text
            lines, match = output.expect /(\{.*)\n/
            begin
              response = JSON.parse match
              raise ChromeError if response["exceptionDetails"]
              response.fetch("result").fetch("value", nil)
            rescue TypeError, JSON::ParserError, KeyError
              raise ChromeError
            end
          end
          scale = command.call %Q[document.getElementById("scale").getBoundingClientRect().width]
          @widths = GLYPHS.map do |glyph|
            width = command.call %Q[document.getElementById("text").textContent=#{glyph.inspect}; document.getElementById("text").getBoundingClientRect().width]
            [ glyph, width / scale ]
          end.to_h
          @kernings = GLYPHS.product(GLYPHS).map do |pair|
            width = command.call %Q[document.getElementById("text").textContent=#{pair.join.inspect}; document.getElementById("text").getBoundingClientRect().width]
            [ pair, width / scale - @widths.values_at(*pair).inject(&:+) ]
          end.to_h
          command.call %Q[document.getElementById("text").textContent="abcdefghijklmnopqrstuvwxyz"]
          width1 = command.call %Q[document.getElementById("text").getBoundingClientRect().width]
          command.call %Q[document.getElementById("text").removeAttribute("font-family")]
          width2 = command.call %Q[document.getElementById("text").getBoundingClientRect().width]
          @missing = width1 == width2
          input.puts "quit"
        end
      end if chrome
    rescue ChromeError
      @widths, @kernings, @generic = nil, nil, true
    ensure
      @widths ||= GENERIC_WIDTHS
      @widths.default = @widths[?M]
      @kernings ||= {}
      @kernings.default = 0
    end

    def glyph_length(string, attributes)
      font_size, letter_spacing, word_spacing = attributes.values_at("font-size", "letter-spacing", "word-spacing").map(&:to_f)
      string.chars.each_cons(2).inject(@widths[string[0]] * font_size) do |sum, pair|
        next sum + (@widths[pair[1]] + @kernings[pair]) * font_size + letter_spacing                unless pair[0] == ?\s
        next sum + (@widths[pair[1]] + @kernings[pair]) * font_size + letter_spacing + word_spacing unless pair[1] == ?\s
        sum
      end
    end

    def in_two(string, attributes)
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
  end
end

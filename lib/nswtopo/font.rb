module NSWTopo
  module Font
    module Chrome
      include Log
      ATTRIBUTES = %w[font-family font-variant font-style font-weight font-size letter-spacing word-spacing]
      SVG = <<~XML
        <?xml version='1.0' encoding='UTF-8'?>
        <svg xmlns='http://www.w3.org/2000/svg' width='1mm' height='1mm' viewBox='0 0 1 1' text-rendering='geometricPrecision'>
          <rect width='1' height='1' stroke='none' />
          <text>placeholder</text>
        </svg>
      XML

      def start_chrome
        @families = Set[]
        NSWTopo::Chrome.new("data:image/svg+xml;base64,#{Base64.encode64 SVG}").tap do |browser|
          @scale = browser.query_selector("rect").width
          @text = browser.query_selector "text"
        end
      end

      def self.extended(instance)
        instance.start_chrome
      end

      def validate(attributes)
        return unless family = attributes["font-family"]
        return unless @families.add? family
        @text.value = "abcdefghijklmnopqrstuvwxyz"
        @text[:style] = "font-family:#{family}"
        styled_width = @text.width
        @text[:style] = nil
        unstyled_width = @text.width
        log_neutral "font '#{family}' doesn't appear to be available" if styled_width == unstyled_width
      end

      def glyph_length(string, attributes)
        validate attributes
        style = attributes.slice(*ATTRIBUTES).map do |pair|
          pair.join ?:
        end.join(?;)
        @text[:style] = style
        @text.value = string == ?\s ? "\u00a0" : string
        @text.width / @scale
      end
    end

    extend self

    def glyph_length(*args)
      self.extend Chrome
      glyph_length *args
    end

    def in_two(string, attributes)
      words = string.split(string[?\n] || string[?/] || ?\s).map(&:strip)
      (1...words.size).map do |index|
        [words[0...index].join(?\s), words[index...words.size].join(?\s)]
      end.map do |lines|
        lines.map do |line|
          [line, glyph_length(line, attributes)]
        end
      end.min_by do |lines_widths|
        lines_widths.map(&:last).max
      end || [[words[0], glyph_length(words[0], attributes)]]
    end
  end
end

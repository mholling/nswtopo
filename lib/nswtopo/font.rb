module NSWTopo
  module Font
    module Chrome
      include Log
      ATTRIBUTES = %w[font-family font-variant font-style font-weight font-size letter-spacing word-spacing]

      def start_chrome
        svg = <<~XML
          <?xml version='1.0' encoding='UTF-8'?>
          <svg xmlns='http://www.w3.org/2000/svg' width='1mm' height='1mm' viewBox='0 0 1 1' text-rendering='geometricPrecision'>
            <rect id='mm' width='1' height='1' stroke='none' />
            <text id='text' />
          </svg>
        XML

        @chrome = Ferrum::Browser.new browser_path: Config["chrome"]
        @chrome.goto "data:image/svg+xml;base64,#{Base64.encode64 svg}"

        @mm = @chrome.at_css("#mm").evaluate %Q[this.getBoundingClientRect().width]
        @text = @chrome.at_css("#text")
        @families = Set[]
      rescue Ferrum::Error, Errno::ENOENT
        log_abort "couldn't find or run chrome"
      end

      def self.extended(instance)
        instance.start_chrome
      end

      def validate(attributes)
        return unless family = attributes["font-family"]
        return unless @families.add? family
        @text.evaluate %Q[this.textContent="abcdefghijklmnopqrstuvwxyz"]
        ["font-family:#{family}", ""].map do |style|
          @text.evaluate %Q[this.setAttribute("style", #{style.inspect})]
          @text.evaluate %Q[this.getBoundingClientRect().width]
        end.tap do |specific, generic|
          log_neutral "font '#{family}' doesn't appear to be available" if specific == generic
        end
      end

      def glyph_length(string, attributes)
        validate attributes
        style = attributes.slice(*ATTRIBUTES).tap do |styles|
          styles["white-space"] = "pre" if ?\s == string
        end.map do |pair|
          pair.join ?:
        end.join(?;)
        @text.evaluate %Q[this.setAttribute("style", #{style.inspect})]
        @text.evaluate %Q[this.textContent=#{string.inspect}]
        @text.evaluate(%Q[this.getBoundingClientRect().width]) / @mm
      rescue Ferrum::Error, SystemCallError
        log_abort "couldn't find or run chrome"
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

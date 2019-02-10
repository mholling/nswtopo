module NSWTopo
  module Font
    module Chrome
      ATTRIBUTES = %w[font-family font-variant font-style font-weight font-size letter-spacing word-spacing]

      def command(string)
        @input.puts string
        lines, match = @output.expect(/(\{.*)\n/, 1)
        response = JSON.parse match
        raise "unexpected chrome error: %s" % response.dig("exceptionDetails", "exception", "description") if response["exceptionDetails"]
        response.fetch("result").dig("value")
      rescue TypeError, JSON::ParserError, KeyError
        raise "unexpected chrome error"
      end

      def start_chrome
        chrome_path = Config["chrome"]
        svg = <<~XML
          <?xml version='1.0' encoding='UTF-8'?>
          <svg version='1.1' baseProfile='full' xmlns='http://www.w3.org/2000/svg' width='1mm' height='1mm' viewBox='0 0 1 1'>
            <rect id='mm' width='1' height='1' stroke='none' />
            <text id='text' />
          </svg>
        XML
        @output, @input, @pid = PTY.spawn chrome_path, "--headless", "--disable-gpu", "--repl", "data:image/svg+xml;base64,#{Base64.encode64 svg}"
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
        ["font-family:#{family}", nil].map do |style|
          command %Q[text.setAttribute("style", "#{style}")]
          command %Q[text.getBoundingClientRect().width]
        end.inject(&:==) || return
        log_neutral "font '#{family}' doesn't appear to be available"
      end

      def glyph_length(string, attributes)
        style = attributes.slice(*ATTRIBUTES).map do |pair|
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

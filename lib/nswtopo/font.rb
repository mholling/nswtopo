require_relative 'font/generic'
require_relative 'font/chrome'

module NSWTopo
  module Font
    include Log
    extend self

    def glyph_length(*args)
      chrome_path = Config["chrome"]
      case
      when !defined? PTY
        self.extend Generic
      when !chrome_path
        log_warn "chrome browser not configured - using generic font measurements"
        self.extend Generic
      else
        begin
          stdout, stderr, status = Open3.capture3 chrome_path, "--version"
          raise unless status.success?
          self.extend Chrome
        rescue Errno::ENOENT, RuntimeError
          log_warn "couldn't run chrome - using generic font measurements"
          self.extend Generic
        end
      end
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

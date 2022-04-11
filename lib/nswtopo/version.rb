module NSWTopo
  class Version
    include Comparable
    Error = Class.new StandardError

    def self.[](creator_string)
      raise Error unless digit_string = creator_string.to_s[/^nswtopo (\d+(\.\d+(\.\d+)?)?)$/, 1]
      new digit_string
    end

    def creator_string
      "nswtopo #{self}"
    end

    def initialize(digit_string)
      @to_s = digit_string
      @to_a = digit_string.split(?.).map(&:to_i)
    end

    attr_reader :to_s, :to_a

    def <=>(other)
      self.to_a <=> other.to_a
    end
  end

  VERSION     = Version["nswtopo 2.0.0"]
  MIN_VERSION = Version["nswtopo 2.0.0"]
end

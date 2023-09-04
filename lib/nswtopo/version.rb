module NSWTopo
  class Version
    include Comparable
    Error = Class.new StandardError

    def self.[](creator_string)
      /^nswtopo (?<digit_string>\d+(\.\d+(\.\d+)?)?)$/ =~ creator_string.to_s
      digit_string ? new(digit_string) : raise(Error)
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

  VERSION     = Version["nswtopo 3.1"]
  MIN_VERSION = Version["nswtopo 3.0"]
end

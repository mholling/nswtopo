module NSWTopo
  class Colour
    def initialize(string_or_array)
      @triplet = case string_or_array
      when Array then string_or_array.take(3).map(&:round)
      when /^#([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})$/i
        [ $1, $2, $3 ].map { |hex| Integer("0x#{hex}") }
      when /^rgb\((\d{1,3}),(\d{1,3}),(\d{1,3})\)$/
        [ $1, $2, $3 ].map(&:to_i)
      end
      raise "invalid colour: #{string_or_array}" unless @triplet&.all?(0..255)
    end
    attr_reader :triplet

    def mix(other, fraction)
      Colour.new [ triplet, other.triplet ].along(fraction.to_f).map(&:to_i)
    end
  end
end

module NSWTopo
  class ESRIHdr
    def initialize(path_or_object, *args)
      @header = case path_or_object
      when Pathname then path_or_object.sub_ext(".hdr").each_line.map(&:upcase).map(&:split).to_h
      when ESRIHdr then path_or_object.header.dup
      end

      @format = case @header.values_at "PIXELTYPE", "NBITS", "BYTEORDER"
      when %w[SIGNEDINT 8 I]    then "c*"
      when %w[SIGNEDINT 8 M]    then "c*"
      when %w[SIGNEDINT 16 I]   then "s<*"
      when %w[SIGNEDINT 16 M]   then "s>*"
      when %w[SIGNEDINT 32 I]   then "l<*"
      when %w[SIGNEDINT 32 M]   then "l>*"
      when %w[UNSIGNEDINT 8 I]  then "C*"
      when %w[UNSIGNEDINT 8 M]  then "C*"
      when %w[UNSIGNEDINT 16 I] then "S<*"
      when %w[UNSIGNEDINT 16 M] then "S>*"
      when %w[UNSIGNEDINT 32 I] then "L<*"
      when %w[UNSIGNEDINT 32 M] then "L>*"
      when %w[FLOAT 32 I]       then "e*"
      when %w[FLOAT 32 M]       then "g*"
      end

      @nodata = case path_or_object
      when Pathname
        case @header.values_at "PIXELTYPE", "NBITS"
        when %w[SIGNEDINT 8]    then args.take(1).pack("c").unpack("c").first
        when %w[UNSIGNEDINT 8]  then args.take(1).pack("C").unpack("C").first
        when %w[SIGNEDINT 16]   then args.take(1).pack("s").unpack("s").first
        when %w[UNSIGNEDINT 16] then args.take(1).pack("S").unpack("S").first
        when %w[SIGNEDINT 32]   then args.take(1).pack("l").unpack("l").first
        when %w[UNSIGNEDINT 32] then args.take(1).pack("L").unpack("L").first
        when %w[FLOAT 32]       then args.first
        else abort @header.inspect
        end if args.any?
      when ESRIHdr then path_or_object.nodata
      end

      @values = case path_or_object
      when Pathname
        path_or_object.sub_ext(".bil").binread.unpack(@format).map do |value|
          value == @nodata ? nil : value
        end
      when ESRIHdr then args[0]
      end
    end

    def write(path)
      @header.map do |pair|
        "%-#{@header.keys.map(&:length).max}s  %s\n" % pair
      end.join('').tap do |text|
        path.sub_ext(".hdr").write text
      end
      @values.map do |value|
        value || @nodata
      end.pack(@format).tap do |data|
        path.sub_ext(".bil").binwrite data
      end
    end

    attr_reader :header, :values, :nodata

    def nrows
      @nrows ||= @header["NROWS"].to_i
    end

    def ncols
      @ncols ||= @header["NCOLS"].to_i
    end

    def rows
      @values.each_slice ncols
    end
  end
end

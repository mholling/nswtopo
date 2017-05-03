module NSWTopo
  class AAIGrid
    def initialize(path_or_object, *args)
      @values, nodata = *args
      @header = case path_or_object
      when Pathname
        2.times.inject(nil) do |header|
          path_or_object.each_line.take(header ? path_or_object.each_line.count - header["nrows"] : 2).map(&:split).map do |key, value|
            [ key, (Integer(value) rescue Float(value)) ]
          end.to_h
        end
      when AAIGrid
        path_or_object.header.dup
      end
      @header["NODATA_value"] = nodata if nodata
      @ncols, @nodata = @header.values_at "ncols", "NODATA_value"
      @values ||= path_or_object.each_line.drop(@header.length).map(&:split).map do |values|
        values.map do |value|
          Integer(value) rescue Float(value)
        end.map do |value|
          value == @nodata ? nil : value
        end
      end.flatten
    end
    
    def write(path)
      path.open "w" do |file|
        @header.each do |key, value|
          file.puts "%-#{@header.keys.map(&:length).max}s #{value}" % key
        end
        @values.map do |value|
          value || @nodata
        end.each_slice(@ncols) do |row|
          file.puts row.join(?\s)
        end
      end
    end
    
    attr_reader :header, :values
    
    def rows
      @values.each_slice @ncols
    end
  end
end

module Enumerable
  def recover(*exceptions)
    Enumerator.new do |yielder|
      each do |element|
        begin
          yielder.yield element
        rescue *exceptions => e
          $stderr.puts "\nError: #{e.message}"
          next
        end
      end
    end
  end
end

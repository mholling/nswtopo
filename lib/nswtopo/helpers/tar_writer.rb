module TarWriterHelpers
  def add_entry(entry)
    check_closed
    @io.write entry.header
    @io.write entry.read
    @io.write ?\0 while @io.pos % 512 > 0
    self
  end
end

Gem::Package::TarWriter.send :include, TarWriterHelpers

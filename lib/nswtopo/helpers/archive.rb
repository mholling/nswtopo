module NSWTopo
  class Archive
    def initialize(path, tar_in)
      @tar_in, @basename, @entries = tar_in, path.basename(".tgz").basename(".tar.gz").to_s, Hash[]
    end
    attr_reader :basename

    def delete(filename)
      @entries[filename] = nil
    end

    def write(filename, content)
      io = StringIO.new content
      header = Gem::Package::TarHeader.new name: filename, size: io.size, prefix: "", mode: 0o0644, mtime: Time.now
      @entries[filename] = Gem::Package::TarReader::Entry.new header, io
    end

    def mtime(filename)
      header = @entries.key?(filename) ? @entries[filename]&.header : @tar_in.seek(filename, &:header)
      Time.at header.mtime if header
    end

    def read(filename)
      @entries.key?(filename) ? @entries[filename]&.read : @tar_in.seek(filename, &:read)
    ensure
      @entries[filename]&.rewind
    end

    def uptodate?(depender, *dependees)
      return unless mtime(depender)
      dependees.all? do |dependee|
        mtimes = [ depender, dependee ].map(&method(:mtime))
        mtimes.all? && mtimes.inject(&:>=)
      end
    end

    def each(&block)
      @tar_in.each do |entry|
        yield entry unless @entries.key? entry.full_name
      end
      @entries.each do |filename, entry|
        yield entry if entry
      end
    end

    def changed?
      return true if @entries.values.any?
      @entries.keys.any? do |filename|
        @tar_in.seek(filename, &:itself)
      end
    end

    def self.open(out_path, in_path = nil, &block)
      buffer, reader = StringIO.new, in_path ? Zlib::GzipReader : StringIO

      reader.open(*in_path) do |input|
        Gem::Package::TarReader.new(input) do |tar_in|
          archive = new(out_path, tar_in).tap(&block)
          Gem::Package::TarWriter.new(buffer) do |tar_out|
            archive.each(&tar_out.method(:add_entry))
          end if archive.changed?
        end
      end

      begin
        # TODO: extract as #safely method so we can use it for Formats writing as well
        Zlib::GzipWriter.open(out_path, Zlib::BEST_COMPRESSION) do |gzip|
          gzip.write buffer.string
        end
      rescue Interrupt => interrupt
        warn "\r\033[Knswtopo: saving map file, please wait..."
        retry
      end unless buffer.size.zero?
      raise interrupt if interrupt

    rescue Zlib::GzipFile::Error
      raise "unrecognised map file: #{in_path}"
    end
  end
end

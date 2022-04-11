module NSWTopo
  class Archive
    extend Safely

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
        mtimes = [depender, dependee].map(&method(:mtime))
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
        begin
          version = Version[input.comment]
          raise "map file too old: created with nswtopo %s, minimum %s required" % [version, MIN_VERSION] unless version >= MIN_VERSION
          raise "nswtopo too old: map file created with nswtopo %s, this version %s" % [version, VERSION] unless version <= VERSION
        rescue Version::Error
          raise "unrecognised map file: %s" % in_path
        end if in_path
        Gem::Package::TarReader.new(input) do |tar_in|
          archive = new(out_path, tar_in).tap(&block)
          Gem::Package::TarWriter.new(buffer) do |tar_out|
            archive.each &tar_out.method(:add_entry)
          end if archive.changed?
        end
      end

      Dir.mktmppath do |temp_dir|
        log_update "nswtopo: saving map..."
        temp_path = temp_dir / "temp.tgz"
        Zlib::GzipWriter.open temp_path, Config["zlib-level"] || Zlib::BEST_SPEED do |gzip|
          gzip.comment = VERSION.creator_string
          gzip.write buffer.string
        rescue Interrupt
          log_update "nswtopo: interrupted, please wait..."
          raise
        end
        safely "saving map file, please wait..." do
          FileUtils.cp temp_path, out_path
        end
        log_success "map saved"
      end unless buffer.size.zero?

    rescue Zlib::GzipFile::Error
      raise "unrecognised map file: %s" % in_path
    end
  end
end

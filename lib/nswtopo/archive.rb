module NSWTopo
  class Archive
    extend Safely
    include Enumerable
    Invalid = Class.new RuntimeError

    def initialize(tar)
      @tar, @entries = tar, Hash[]
    end

    def write(filename, content)
      io = StringIO.new content
      header = Gem::Package::TarHeader.new name: filename, size: io.size, prefix: "", mode: 0o0644, mtime: Time.now
      @entries[filename] = Gem::Package::TarReader::Entry.new header, io
    end

    def each(&block)
      @tar.rewind
      @tar.each do |entry|
        yield entry unless @entries.key? entry.full_name
      end
      @entries.each do |filename, entry|
        yield entry if entry
      end
    end

    def delete(filename)
      find do |entry|
        entry.full_name == filename
      end&.tap do
        @entries[filename] = nil
      end
    end

    def read(filename)
      find do |entry|
        entry.full_name == filename
      end&.read
    end

    def mtime(filename)
      find do |entry|
        entry.full_name == filename
      end&.yield_self do |entry|
        Time.at entry.header.mtime
      end
    end

    def uptodate?(depender, *dependees)
      return unless mtime(depender)
      dependees.all? do |dependee|
        mtimes = [depender, dependee].map(&method(:mtime))
        mtimes.all? && mtimes.inject(&:>=)
      end
    end

    def changed?
      @entries.any?
    end

    def self.open(out_path: nil, in_path: nil, &block)
      buffer, reader = StringIO.new, in_path ? Zlib::GzipReader : StringIO

      reader.open(*in_path) do |input|
        begin
          version = Version[input.comment]
          raise "map file too old: created with nswtopo %s, minimum %s required" % [version, MIN_VERSION] unless version >= MIN_VERSION
          raise "nswtopo too old: map file created with nswtopo %s, this version %s" % [version, VERSION] unless version <= VERSION
        rescue Version::Error
          raise "unrecognised map file: %s" % in_path
        end if in_path
        Gem::Package::TarReader.new(input) do |tar|
          archive = new(tar).tap(&block)
          Gem::Package::TarWriter.new(buffer) do |tar|
            archive.each &tar.method(:add_entry)
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
        rescue SystemCallError
          raise "couldn't save #{out_path}"
        end
        log_success "map saved"
      end if out_path && buffer.size.nonzero?

    rescue Zlib::GzipFile::Error
      raise Invalid
    end
  end
end

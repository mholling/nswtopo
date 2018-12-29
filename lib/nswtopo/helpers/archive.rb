module NSWTopo
  class Archive
    def initialize(tar_in, tar_out, changed)
      @tar_in, @tar_out, @changed = tar_in, tar_out, changed
    end

    def write(filename, content)
      @changed << filename
      @tar_out.add_file(filename, 0o0644) do |io|
        io.write content
      end
    end

    def mtime(filename)
      header = @tar_in.seek(filename, &:header)
      Time.at header.mtime if header
    end

    def delete(filename)
      @changed << filename
    end

    def read(filename)
      @tar_in.seek(filename, &:read)
    end

    def self.open(out_path, in_path = nil)
      buffer, changed = StringIO.new, Set[]

      (in_path ? Zlib::GzipReader : StringIO).open(*in_path) do |input|
        Gem::Package::TarReader.new(input) do |tar_in|
          Gem::Package::TarWriter.new(buffer) do |tar_out|
            yield new(tar_in, tar_out, changed)
            tar_in.each do |entry|
              next if changed === entry.full_name
              tar_out.add_entry entry
            end if changed.any?
          end
        end
      end

      begin
        Zlib::GzipWriter.open(out_path, Zlib::BEST_COMPRESSION) do |gzip|
          gzip.write buffer.string
        end
      rescue Interrupt => interrupt
        warn "\r\033[Knswtopo: saving map file, please wait..."
        retry
      end if changed.any?
      raise interrupt if interrupt

    rescue Zlib::GzipFile::Error
      raise "unrecognised map file: #{out_path}"
    end
  end
end

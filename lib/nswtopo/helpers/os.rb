module NSWTopo
  module OS
    Error = Class.new RuntimeError
    Missing = Class.new RuntimeError

    GDAL = %w[
      gdal_contour
      gdal_grid
      gdal_rasterize
      gdal_translate
      gdaladdo
      gdalbuildvrt
      gdaldem
      gdalenhance
      gdalinfo
      gdallocationinfo
      gdalmanage
      gdalserver
      gdalsrsinfo
      gdaltindex
      gdaltransform
      gdalwarp
      gnmanalyse
      gnmmanage
      nearblack
      ogr2ogr
      ogrinfo
      ogrlineref
      ogrtindex
      testepsg
    ]
    ImageMagick = %w[
      animate
      compare
      composite
      conjure
      convert
      display
      identify
      import
      mogrify
      montage
      stream
    ]
    SQLite3 = %w[sqlite3]
    PNGQuant = %w[pngquant]
    GIMP = %w[gimp]

    extend self

    %w[GDAL ImageMagick SQLite3 PNGQuant GIMP].each do |package|
      OS.const_get(package).each do |command|
        define_method command do |*args, &block|
          Open3.popen3 command, *args.map(&:to_s) do |stdin, stdout, stderr, thread|
            begin
              block.call(stdin) if block
            rescue Errno::EPIPE
            ensure
              stdin.close
            end
            out = Thread.new { stdout.read }
            err = Thread.new { stderr.read }
            raise Error, "#{command}: #{err.value.empty? ? out.value : err.value}" unless thread.value.success?
            out.value
          end
        rescue Errno::ENOENT
          raise Missing, "#{package} not installed"
        end
      end
    end

    def zip(directory, archive)
      raise Error, "zip: #{directory} is not a directory" unless directory.directory?
      [%w[zip -r] << archive.expand_path, %w[7z a -tzip -r] << archive.expand_path].find do |command, *args|
        Dir.chdir directory do
          args += Pathname.glob('*')
          stdout, stderr, status = Open3.capture3 command, *args.map(&:to_s)
          status.success? || raise(Error, "#{command}: #{stderr.empty? ? stdout : stderr}")
        end
      rescue Errno::ENOENT
        next
      end || raise(Missing, "no zip utility installed")
      true
    end
  end
end

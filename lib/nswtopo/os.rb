module NSWTopo
  module OS
    Error = Class.new RuntimeError
    Missing = Class.new RuntimeError

    GDAL = %w[
      gdal_contour
      gdal_grid
      gdal_translate
      gdalbuildvrt
      gdaldem
      gdalinfo
      gdallocationinfo
      gdalmanage
      gdalsrsinfo
      gdaltransform
      gdalwarp
      ogr2ogr
      ogrinfo
    ]
    ImageMagick = %w[magick]
    SQLite3 = %w[sqlite3]
    PNGQuant = %w[pngquant]
    GIMP = %w[gimp]
    Zip = %w[zip]
    SevenZ = %w[7z]

    extend self

    %w[GDAL ImageMagick SQLite3 PNGQuant GIMP Zip SevenZ].each do |package|
      OS.const_get(package).each do |command|
        define_method command do |*args, &block|
          Open3.popen3 command, *args.map(&:to_s) do |stdin, stdout, stderr, thread|
            thr_in = Thread.new do
              block.call(stdin) if block
            rescue Errno::EPIPE
            ensure
              stdin.close
            end
            thr_out = Thread.new { stdout.read }
            thr_err = Thread.new { stderr.read }
            [thr_in, thr_out, thr_err].each(&:join)
            raise Error, "#{command}: #{thr_err.value.empty? ? thr_out.value : thr_err.value}" unless thread.value.success?
            thr_out.value
          end
        rescue Errno::ENOENT
          raise Missing, "#{package} not installed"
        end
      end
    end
  end
end

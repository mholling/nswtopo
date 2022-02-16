module NSWTopo
  module Dither
    Missing = Class.new RuntimeError

    def dither(*png_paths)
      Enumerator.new do |yielder|
        yielder << -> { OS.pngquant *%w[--quiet --force --ext .png --speed 1 --nofs], *png_paths }
        gimp_script = <<~EOF
          (map
            (lambda (path)
              (let*
                (
                  (image (car (gimp-file-load RUN-NONINTERACTIVE path path)))
                  (drawable (car (gimp-image-get-active-layer image)))
                )
                (gimp-image-convert-indexed image FSLOWBLEED-DITHER MAKE-PALETTE 256 FALSE FALSE "")
                (gimp-file-save RUN-NONINTERACTIVE image drawable path path)
              )
            )
            (list "#{png_paths.join ?\s}")
          )
        EOF
        yielder << -> { OS.gimp "-c", "-d", "-f", "-i", "-b", gimp_script, "-b", "(gimp-quit TRUE)" }
        yielder << -> { OS.magick *%w[mogrify -type PaletteBilevelAlpha -dither Riemersma -colors 256], *png_paths }
        raise Missing, "pngquant, GIMP or ImageMagick required for dithering"
      end.each do |dither|
        dither.call
        break
      rescue OS::Missing
      end
    end
  end
end

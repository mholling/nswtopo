module NSWTopo
  module Dither
    def dither(*png_paths)
      case
      when pngquant = CONFIG["pngquant"]
        %x["#{pngquant}" --quiet --force --ext .png --speed 1 --nofs "#{png_paths.join '" "'}"]
      when gimp = CONFIG["gimp"]
        script = %Q[
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
            (list "#{png_paths.join '" "'}")
          )
        ]
        %x["#{gimp}" -c -d -f -i -b '#{script}' -b '(gimp-quit TRUE)' #{DISCARD_STDERR}]
      else
        %x[mogrify -type PaletteBilevelAlpha -dither Riemersma "#{png_paths.join '" "'}"]
      end if png_paths.any?
    end
  end
end

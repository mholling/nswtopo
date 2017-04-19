module NSWTopo
  module Dither
    def dither(binary, *png_paths)
      case binary
      when /gimp/i
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
        %x["#{binary}" -c -d -f -i -b '#{script}' -b '(gimp-quit TRUE)' #{DISCARD_STDERR}]
      when /pngquant/i
        %x["#{binary}" --quiet --force --ext .png "#{png_paths.join '" "'}"]
      when true
        %x[mogrify -type PaletteBilevelAlpha -dither Riemersma "#{png_paths.join '" "'}"]
      when String
        abort "Unrecognised dither option: #{binary}"
      end if png_paths.any?
    end
  end
end

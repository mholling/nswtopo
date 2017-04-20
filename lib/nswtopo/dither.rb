module NSWTopo
  module Dither
    def dither(config, *png_paths)
      binary = String === config["dither"] ? config["dither"] : config["pngquant"] || config["gimp"] || true
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
      when String
        abort "Unrecognised dither option: #{binary}"
      else
        %x[mogrify -type PaletteBilevelAlpha -dither Riemersma "#{png_paths.join '" "'}"]
      end if png_paths.any?
    end
  end
end

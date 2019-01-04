module NSWTopo
  module Formats
    module Png
      def render_png(temp_dir, out_path, ppi:, dither: false, **options)
        # TODO: handle dithering if requested
        FileUtils.cp yield(ppi: ppi), out_path
      end
    end
  end
end

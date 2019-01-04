module NSWTopo
  module Formats
    module Tif
      def render_tif(temp_dir, tif_path, ppi:, dither: false, **options)
        # TODO: handle dithering if requested
        OS.gdal_translate "-of", "GTiff", "-a_srs", @projection, yield(ppi: ppi), tif_path
      end
    end
  end
end

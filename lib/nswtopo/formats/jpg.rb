module NSWTopo
  module Formats
    module Jpg
      def render_jpg(temp_dir, jpg_path, ppi:, **options)
        OS.gdal_translate "-of", "JPEG", yield(ppi: ppi), jpg_path
      end
    end
  end
end

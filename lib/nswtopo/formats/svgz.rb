module NSWTopo
  module Formats
    using Helpers
    def render_svgz(svgz_path, background:, **options)
      Dir.mktmppath do |temp_dir|
        svg_path = temp_dir / "svgz-map.svg"
        render_svg svg_path, background: background
        Zlib::GzipWriter.open svgz_path do |gz|
          gz.write svg_path.binread
        end
      end
    end
  end
end

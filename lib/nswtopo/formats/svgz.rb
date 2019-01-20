module NSWTopo
  module Formats
    def render_svgz(temp_dir, svgz_path, **options)
      svg_path = temp_dir / "svgz-map.svg"
      render_svg temp_dir, svg_path
      Zlib::GzipWriter.open svgz_path do |gz|
        gz.write svg_path.binread
      end
    end
  end
end

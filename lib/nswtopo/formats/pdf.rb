module NSWTopo
  module Formats
    def render_pdf(pdf_path, ppi: nil, external: nil, **options)
      if ppi
        OS.gdal_translate "-a_srs", @projection, "-of", "PDF", "-co", "DPI=#{ppi}", "-co", "MARGIN=0", "-co", "CREATOR=nswtopo", "-co", "GEO_ENCODING=ISO32000", yield(ppi: ppi), pdf_path
      else
        Dir.mktmppath do |temp_dir|
          svg_path = temp_dir / "pdf-map.svg"
          render_svg svg_path, external: external
          xml = REXML::Document.new svg_path.read
          style = "@media print { @page { margin: 0 0 -1mm 0; size: %s %s; } }"
          svg = xml.elements["svg"]
          svg.add_element("style").text = style % svg.attributes.values_at("width", "height")
          svg_path.write xml

          FileUtils.rm pdf_path if pdf_path.exist?
          Config["chrome"].tap do |chrome_path|
            raise "please configure a path for google chrome" unless chrome_path
            args = %W[--headless --disable-gpu --print-to-pdf=#{pdf_path}]
            stdout, stderr, status = Open3.capture3 chrome_path, *args, "file://#{svg_path}"
            raise "couldn't create PDF using chrome" unless status.success? && pdf_path.file?
          rescue Errno::ENOENT
            raise "invalid chrome path: %s" % chrome_path
          end
        end
      end
    end
  end
end

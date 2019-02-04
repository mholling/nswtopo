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
          NSWTopo.with_browser do |browser_name, browser_path|
            args = case browser_name
            when "chrome"
              ["--headless", "--disable-gpu", "--print-to-pdf=#{pdf_path}"]
            when "firefox"
              raise "can't create vector PDF with firefox; use chrome or specify ppi for a raster PDF"
            end
            stdout, stderr, status = Open3.capture3 browser_path.to_s, *args, "file://#{svg_path}"
            raise "couldn't create PDF using %s" % browser_name unless status.success? && pdf_path.file?
          end
        end
      end
    end
  end
end

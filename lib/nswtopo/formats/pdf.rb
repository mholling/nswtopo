module NSWTopo
  module PDF
    def self.build(ppi, src_path, temp_dir, pdf_path)
      case
      when ppi
        %x[gdal_translate -a_srs "#{CONFIG.map.projection}" -of PDF -co DPI=#{ppi} -co MARGIN=0 -co CREATOR=nswtopo -co "TITLE=#{CONFIG.map.name}" "#{src_path}" "#{output_path}"]
      when wkhtmltopdf = CONFIG["wkhtmltopdf"]
        xml = REXML::Document.new(src_path.read)
        width, height = %w[width height].map { |name| xml.elements["/svg"].attributes[name] }
        %x["#{wkhtmltopdf}" --quiet --margin-bottom 0mm --margin-left 0mm --margin-right 0mm --margin-top 0mm --page-width #{width} --page-height #{height} --title "#{CONFIG.map.name}" "#{src_path}" "#{pdf_path}"]
      when inkscape = CONFIG["inkscape"]
        %x["#{inkscape}" --without-gui --file="#{src_path}" --export-pdf="#{pdf_path}" #{DISCARD_STDERR}]
      when phantomjs = CONFIG["phantomjs"]
        xml = REXML::Document.new(src_path.read)
        width, height = %w[width height].map { |name| xml.elements["/svg"].attributes[name] }
        js_path = temp_dir + "makepdf.js"
        File.write js_path, %Q[
          var page = require('webpage').create();
          page.paperSize = { width: '#{width}', height: '#{height}' };
          page.open('#{src_path.to_s.gsub(?', "\\\\\'")}', function(status) {
              page.render('#{pdf_path.to_s.gsub(?', "\\\\\'")}');
              phantom.exit();
          });
        ]
        %x["#{phantomjs}" "#{js_path}"]
      else
        abort("Error: please specify a path to Inkscape before creating PDF output (see README).")
      end
    end
  end
end

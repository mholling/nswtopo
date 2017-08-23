module NSWTopo
  module PDF
    def self.build(svg_path, temp_dir, pdf_path)
      case
      when inkscape = CONFIG["inkscape"]
        %x["#{inkscape}" --without-gui --file="#{svg_path}" --export-pdf="#{pdf_path}" #{DISCARD_STDERR}]
      when phantomjs = CONFIG["phantomjs"]
        xml = REXML::Document.new(svg_path.read)
        width, height = %w[width height].map { |name| xml.elements["/svg"].attributes[name] }
        js_path = temp_dir + "makepdf.js"
        File.write js_path, %Q[
          var page = require('webpage').create();
          page.paperSize = { width: '#{width}', height: '#{height}' };
          page.open('#{svg_path.to_s.gsub(?', "\\\\\'")}', function(status) {
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

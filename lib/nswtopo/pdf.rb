module NSWTopo
  module PDF
    def self.build(config, map, svg_path, temp_dir, pdf_path)
      rasterise = config["rasterise"]
      case rasterise
      when /inkscape/i
        %x["#{rasterise}" --without-gui --file="#{svg_path}" --export-pdf="#{pdf_path}" #{DISCARD_STDERR}]
      when /batik/
        jar_path = Pathname.new(rasterise).expand_path + "batik-rasterizer.jar"
        java = config["java"] || "java"
        %x[#{java} -jar "#{jar_path}" -d "#{pdf_path}" -bg 255.255.255.255 -m application/pdf "#{svg_path}"]
      when /rsvg-convert/
        %x["#{rasterise}" --background-color white --format pdf --output "#{pdf_path}" "#{svg_path}"]
      when "qlmanage"
        raise NoVectorPDF.new("qlmanage")
      when /phantomjs/
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
        %x["#{rasterise}" "#{js_path}"]
      else
        abort("Error: specify either inkscape or phantomjs as your rasterise method (see README).")
      end
    end
  end
end

module NSWTopo
  module Raster
    def self.build(config, map, ppi, svg_path, temp_dir, png_path)
      dimensions = map.dimensions_at(ppi)
      rasterise = config["rasterise"]
      case rasterise
      when /inkscape/i
        %x["#{rasterise}" --without-gui --file="#{svg_path}" --export-png="#{png_path}" --export-width=#{dimensions.first} --export-height=#{dimensions.last} --export-background="#FFFFFF" #{DISCARD_STDERR}]
      when /batik/
        args = %Q[-d "#{png_path}" -bg 255.255.255.255 -m image/png -w #{dimensions.first} -h #{dimensions.last} "#{svg_path}"]
        jar_path = Pathname.new(rasterise).expand_path + "batik-rasterizer.jar"
        java = config["java"] || "java"
        %x[#{java} -jar "#{jar_path}" #{args}]
      when /rsvg-convert/
        %x["#{rasterise}" --background-color white --format png --output "#{png_path}" --width #{dimensions.first} --height #{dimensions.last} "#{svg_path}"]
      when "qlmanage"
        square_svg_path = temp_dir + "square.svg"
        square_png_path = temp_dir + "square.svg.png"
        xml = REXML::Document.new(svg_path.read)
        millimetres = map.extents.map { |extent| 1000.0 * extent / map.scale }
        xml.elements["/svg"].attributes["width"] = "#{millimetres.max}mm"
        xml.elements["/svg"].attributes["height"] = "#{millimetres.max}mm"
        xml.elements["/svg"].attributes["viewBox"] = "0 0 #{millimetres.max} #{millimetres.max}"
        File.write square_svg_path, xml
        %x[qlmanage -t -s #{dimensions.max} -o "#{temp_dir}" "#{square_svg_path}"]
        %x[convert "#{square_png_path}" -crop #{dimensions.join ?x}+0+0 +repage "#{png_path}"]
      when /phantomjs/i
        js_path   = temp_dir + "rasterise.js"
        page_path = temp_dir + "rasterise.svg"
        out_path  = temp_dir + "rasterise.png"
        File.write js_path, %Q[
          var page = require('webpage').create();
          page.viewportSize = { width: 1, height: 1 };
          page.open('#{page_path}', function(status) {
              page.render('#{out_path}');
              phantom.exit();
          });
        ]
        test = REXML::Document.new
        test << REXML::XMLDecl.new(1.0, "utf-8")
        test.add_element("svg", "version" => 1.1, "baseProfile" => "full", "xmlns" => "http://www.w3.org/2000/svg", "width"  => "1in", "height" => "1in")
        page_path.open("w") { |file| test.write file }
        %x["#{rasterise}" "#{js_path}"]
        screen_ppi = %x[identify -format "%w" "#{out_path}"].to_f
        xml = REXML::Document.new(svg_path.read)
        svg = xml.elements["/svg"]
        %w[width height].each do |name|
          attribute = svg.attributes[name]
          svg.attributes[name] = attribute.sub /\d+(\.\d+)?/, (attribute.to_f * ppi / screen_ppi).to_s
        end
        xml.elements.each("//image[@xlink:href]") do |image|
          next if image.attributes["xlink:href"] =~ /^data:/
          image.attributes["xlink:href"] = Pathname.pwd + image.attributes["xlink:href"]
        end
        page_path.open("w") { |file| xml.write file }
        %x["#{rasterise}" "#{js_path}"]
        # TODO: crop to exact size
        FileUtils.cp out_path, png_path
      else
        abort("Error: specify either phantomjs, inkscape or qlmanage as your rasterise method (see README).")
      end
      case
      when config["dither"] && config["gimp"]
        script_path = temp_dir + "dither.scm"
        File.write script_path, %Q[
          (let*
            (
              (image (car (gimp-file-load RUN-NONINTERACTIVE "#{png_path}" "#{png_path}")))
              (drawable (car (gimp-image-get-active-layer image)))
            )
            (gimp-image-convert-indexed image FSLOWBLEED-DITHER MAKE-PALETTE 256 FALSE FALSE "")
            (gimp-file-save RUN-NONINTERACTIVE image drawable "#{png_path}" "#{png_path}")
            (gimp-quit TRUE)
          )
        ]
        %x[mogrify -background white -alpha Remove "#{png_path}"]
        %x[cat "#{script_path}" | "#{config['gimp']}" -c -d -f -i -b -]
        %x[mogrify -units PixelsPerInch -density #{ppi} "#{png_path}"]
      when config["dither"]
        %x[mogrify -units PixelsPerInch -density #{ppi} -background white -alpha Remove -type Palette -dither Riemersma -define PNG:exclude-chunk=bkgd "#{png_path}"]
      else
        %x[mogrify -units PixelsPerInch -density #{ppi} -background white -alpha Remove "#{png_path}"]
      end
    end
  end
end

module NSWTopo
  module Raster
    TILE_SIZE = 2000
    
    def self.build(config, map, ppi, svg_path, temp_dir, png_path)
      width, height = dimensions = map.dimensions_at(ppi)
      yield dimensions if block_given?
      rasterise, dpi = config["rasterise"]
      zoom = ppi.to_f / (dpi || 96)
      case rasterise
      when /inkscape/i
        %x["#{rasterise}" --without-gui --file="#{svg_path}" --export-png="#{png_path}" --export-width=#{width} --export-height=#{height} --export-background="#FFFFFF" #{DISCARD_STDERR}]
      when /batik/
        args = %Q[-d "#{png_path}" -bg 255.255.255.255 -m image/png -w #{width} -h #{height} "#{svg_path}"]
        jar_path = Pathname.new(rasterise).expand_path + "batik-rasterizer.jar"
        java = config["java"] || "java"
        %x[#{java} -jar "#{jar_path}" #{args}]
      when /rsvg-convert/
        %x["#{rasterise}" --background-color white --format png --output "#{png_path}" --width #{width} --height #{height} "#{svg_path}"]
      when "qlmanage"
        square_svg_path = temp_dir + "square.svg"
        square_png_path = temp_dir + "square.svg.png"
        xml = REXML::Document.new(svg_path.read)
        millimetres = map.extents.map { |extent| 1000.0 * extent / map.scale }
        xml.elements["/svg"].attributes["width"] = "#{dimensions.max}px"
        xml.elements["/svg"].attributes["height"] = "#{dimensions.max}px"
        xml.elements["/svg"].attributes["viewBox"] = "0 0 #{millimetres.max} #{millimetres.max}"
        File.write square_svg_path, xml
        %x[qlmanage -t -s #{dimensions.max} -o "#{temp_dir}" "#{square_svg_path}" #{DISCARD_STDERR}]
        %x[convert "#{square_png_path}" -crop #{width}x#{height}+0+0 +repage "#{png_path}"]
      when /phantomjs|slimerjs/i
        js_path = temp_dir + "rasterise.js"
        js_path.write %Q[
          const page = require('webpage').create()
          page.zoomFactor = #{zoom}
          page.open('#{svg_path}', function() {
            page.clipRect = { top: 0, left: 0, width: #{width}, height: #{height} }
            page.render('#{png_path}')
            phantom.exit()
          })
        ]
        %x["#{rasterise}" "#{js_path}"]
      when /electron/i
        src_path, js_path, tile_path = temp_dir + "#{map.name}.zoomed.svg", temp_dir + "rasterise.js", temp_dir + "tile"
        xml = svg_path.read
        %w[width height].each do |name|
          xml.sub! /(<svg[^>]*#{name}\s*=\s*['"])([\d\.e\+\-]+)/i do |match|
            "#{$1}#{$2.to_f * zoom}"
          end
        end
        src_path.write xml
        js_path.write %Q[
          const {app, BrowserWindow, ipcMain} = require('electron'), {writeFile} = require('fs')
          var tiles = [];
          for (var x = 0; x < #{dimensions[0]}; x += #{TILE_SIZE})
            for (var y = 0; y < #{dimensions[1]}; y += #{TILE_SIZE})
              tiles.push({ rect: { x: x, y: y, width: Math.min(#{dimensions[0]}-x, #{TILE_SIZE}), height: Math.min(#{dimensions[1]}-y, #{TILE_SIZE}) }, path: '#{tile_path}.'+x+'.'+y+'.png' })
          app.on('ready', () => {
            const browser = new BrowserWindow({ width: #{width + 100}, height: #{height + 100}, useContentSize: true, show: false })
            function get_tile() {
              var tile = tiles.shift();
              browser.capturePage(tile.rect, image => writeFile(tile.path, image.toPng(), tiles.length ? get_tile : app.exit))
            }
            browser.once('ready-to-show', get_tile)
            browser.loadURL('file://#{src_path}')
          })
          app.dock && app.dock.hide()
        ]
        %x["#{rasterise}" "#{js_path}"]
        sequence = dimensions.map do |dimension|
          0.step(dimension - 1, TILE_SIZE).to_a
        end.inject(&:product).map do |x, y|
          %Q[#{OP} "#{tile_path}.#{x}.#{y}.png" -repage +#{x}+#{y} #{CP}]
        end.join ?\s
        %x[convert #{sequence} -compose Copy -layers mosaic -units PixelsPerInch -density #{ppi} -alpha Remove "#{png_path}"]
      when /wkhtmltoimage/i
        %x["#{rasterise}" -q --width #{width} --height #{height} --zoom #{zoom} "#{svg_path}" "#{png_path}"]
      else
        abort("Error: specify either electron, phantomjs, wkhtmltoimage, inkscape or qlmanage as your rasterise method (see README).")
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
      map.write_world_file Pathname.new("#{png_path}w"), map.resolution_at(ppi)
    end
  end
end

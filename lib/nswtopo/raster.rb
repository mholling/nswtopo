module NSWTopo
  module Raster
    extend Dither
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
        src_path, js_path, preload_path, tile_path = temp_dir + "#{map.name}.zoomed.svg", temp_dir + "rasterise.js", temp_dir + "preload.js", temp_dir + "tile"
        xml = svg_path.read
        xml.sub!(/(<svg[^>]*width\s*=\s*['"])([\d\.e\+\-]+)/i) { "#{$1}#{$2.to_f * zoom}" }
        xml.sub!(/(<svg[^>]*height\s*=\s*['"])([\d\.e\+\-]+)/i) { "#{$1}#{$2.to_f * zoom}" }
        xml.sub!(/(<svg[^>]*)>/i) { "#{$1} style='overflow: hidden'>" }
        src_path.write xml
        preload_path.write %Q[
          const {ipcRenderer} = require('electron')
          ipcRenderer.on('goto', (event, x, y) => {
            window.scrollTo(x, y)
            setTimeout(() => ipcRenderer.send('here', window.scrollX, window.scrollY), 1000)
          })
        ]
        tiles = dimensions.map { |dimension| 0.step(dimension-1, TILE_SIZE).to_a }.inject(&:product)
        js_path.write %Q[
          const {app, BrowserWindow, ipcMain} = require('electron'), {writeFile} = require('fs')
          app.dock && app.dock.hide()
          var tiles = #{tiles.to_json}
          app.on('ready', () => {
            const browser = new BrowserWindow({ width: #{TILE_SIZE}, height: #{TILE_SIZE}, useContentSize: true, show: false, webPreferences: { preload: '#{preload_path}' } })
            const next = () => tiles.length ? browser.webContents.send('goto', ...tiles.shift()) : app.exit()
            browser.once('ready-to-show', next)
            ipcMain.on('here', (event, x, y) => browser.capturePage((image) => writeFile('#{tile_path}.'+x+'.'+y+'.png', image.toPng(), next)))
            browser.loadURL('file://#{src_path}')
          })
        ]
        %x["#{rasterise}" "#{js_path}"]
        sequence = Pathname.glob("#{tile_path}.*.*.png").map do |tile_path|
          tile_path.basename.to_s.match(/\.(\d+)\.(\d+)\.png$/) do
            %Q[#{OP} "#{tile_path}" -repage +#{$1}+#{$2} #{CP}]
          end
        end.join ?\s
        %x[convert #{sequence} -compose Copy -layers mosaic "#{png_path}"]
      when /wkhtmltoimage/i
        %x["#{rasterise}" -q --width #{width} --height #{height} --zoom #{zoom} "#{svg_path}" "#{png_path}"]
      else
        abort("Error: specify either electron, phantomjs, wkhtmltoimage, inkscape or qlmanage as your rasterise method (see README).")
      end
      %x[mogrify +repage -crop #{width}x#{height}+0+0 -units PixelsPerInch -density #{ppi} -background white -alpha Remove -define PNG:exclude-chunk=bkgd "#{png_path}"]
      dither config, png_path if config["dither"]
      map.write_world_file Pathname.new("#{png_path}w"), map.resolution_at(ppi)
    end
  end
end

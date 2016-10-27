module NSWTopo
  module Raster
    def self.build(config, map, ppi, svg_path, temp_dir, png_path)
      width, height = dimensions = map.dimensions_at(ppi)
      rasterise, dpi = config["rasterise"]
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
        zoom = ppi.to_f / (dpi || 96)
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
        zoom = ppi.to_f / (dpi || 96)
        preload_path = temp_dir + "preload.js"
        preload_path.write %Q[
          const {ipcRenderer} = require('electron')
          var start;
          function wait(time) {
            if (!start) start = time
            time && time - start > 15000 ? ipcRenderer.send('really-ready') : window.requestAnimationFrame(wait)
          }
          ipcRenderer.on('wait', () => wait())
        ]
        js_path = temp_dir + "rasterise.js"
        js_path.write %Q[
          const {app, BrowserWindow, ipcMain} = require('electron'), {writeFile} = require('fs')
          app.on('ready', () => {
            const browser = new BrowserWindow({ width: #{width}, height: #{height}, useContentSize: true, show: false, webPreferences: { zoomFactor: #{zoom}, preload: '#{preload_path}' } })
            browser.webContents.once('did-finish-load', () => browser.webContents.insertCSS('svg { overflow: hidden }'))
            browser.once('ready-to-show', () => browser.webContents.send('wait'))
            ipcMain.once('really-ready', () => browser.capturePage(image => writeFile('#{png_path}', image.toPng(), app.exit)))
            browser.loadURL('file://#{svg_path}')
          })
          app.dock && app.dock.hide()
        ]
        %x["#{rasterise}" "#{js_path}"]
      when /wkhtmltoimage/i
        zoom = ppi.to_f / (dpi || 96)
        %x["#{rasterise}" -q --width #{width} --height #{height} --zoom #{zoom} "#{svg_path}" "#{png_path}"]
      else
        abort("Error: specify either phantomjs, wkhtmltoimage, inkscape or qlmanage as your rasterise method (see README).")
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

module NSWTopo
  module Raster
    TILE_SIZE = 2000

    def self.build(ppi, svg_path, temp_dir, png_path)
      width, height = dimensions = MAP.dimensions_at(ppi)
      yield dimensions if block_given?
      zoom = ppi / 96.0
      case
      when chrome = CONFIG["chrome"] || CONFIG["chromium"]
        src_path = temp_dir + "#{MAP.filename}.scaled.svg"
        svg = %w[width height].inject(svg_path.read) do |svg, attribute|
          svg.sub(/#{attribute}='(.*?)mm'/) { %Q[#{attribute}='#{$1.to_f * zoom}mm'] }
        end
        svg.gsub!(/xlink:href='(.*?\.(png|jpg))'/) { %Q[xlink:href='#{Pathname.new($1).expand_path}'] }
        src_path.write svg
        Dir.chdir(temp_dir) do
          %x["#{chrome}" --headless --enable-logging --log-level=1 --disable-lcd-text --hide-scrollbars --window-size=#{width},#{height} --screenshot "file://#{src_path}"]
          FileUtils.mv "screenshot.png", png_path
        end
      when electron = CONFIG["electron"]
        src_path, js_path, preload_path, tile_path = temp_dir + "#{MAP.filename}.zoomed.svg", temp_dir + "rasterise.js", temp_dir + "preload.js", temp_dir + "tile"
        xml = svg_path.read
        xml.sub!(/(<svg[^>]*width\s*=\s*['"])([\d\.e\+\-]+)/i) { "#{$1}#{$2.to_f * zoom}" }
        xml.sub!(/(<svg[^>]*height\s*=\s*['"])([\d\.e\+\-]+)/i) { "#{$1}#{$2.to_f * zoom}" }
        xml.gsub!(/xlink:href='(.*?\.(png|jpg))'/) { %Q[xlink:href='#{Pathname.new($1).expand_path}'] }
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
        %x["#{electron}" "#{js_path}"]
        sequence = Pathname.glob("#{tile_path}.*.*.png").map do |tile_path|
          tile_path.basename.to_s.match(/\.(\d+)\.(\d+)\.png$/) do
            %Q[#{OP} "#{tile_path}" -repage +#{$1}+#{$2} #{CP}]
          end
        end.join ?\s
        %x[convert #{sequence} -compose Copy -layers mosaic "#{png_path}"]
      when phantomjs = CONFIG["phantomjs"] || CONFIG["slimerjs"]
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
        %x["#{phantomjs}" "#{js_path}"]
      when wkhtmltoimage = CONFIG["wkhtmltoimage"]
        %x["#{wkhtmltoimage}" -q --width #{width} --height #{height} --zoom #{zoom} "#{svg_path}" "#{png_path}"]
      when inkscape = CONFIG["inkscape"]
        %x["#{inkscape}" --without-gui --file="#{svg_path}" --export-png="#{png_path}" --export-width=#{width} --export-height=#{height} --export-background="#FFFFFF" #{DISCARD_STDERR}]
      else
        abort("Error: please specify a path to Google Chrome before creating raster output (see README).")
      end
      %x[mogrify +repage -crop #{width}x#{height}+0+0 -units PixelsPerInch -density #{ppi} -background white -alpha Remove -define PNG:exclude-chunk=bkgd "#{png_path}"]
      MAP.write_world_file Pathname.new("#{png_path}w"), MAP.resolution_at(ppi)
    end
  end
end

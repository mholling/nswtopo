module NSWTopo
  class Chrome
    MIN_VERSION = 112
    TIMEOUT_KILL = 5
    TIMEOUT_LOADEVENT = 30
    TIMEOUT_COMMAND = 10
    TIMEOUT_SCREENSHOT = 120

    class Error < RuntimeError
      def initialize(message = "chrome error")
        super
      end
    end

    def self.mac?
      /darwin/ === RbConfig::CONFIG["host_os"]
    end

    def self.windows?
      /mingw|mswin|cygwin/ === RbConfig::CONFIG["host_os"]
    end

    def self.path
      @path ||= case
      when Config["chrome"]
        [Config["chrome"]]
      when mac?
        ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium"]
      when windows?
        ["C:/Program Files/Google/Chrome/Application/chrome.exe", "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe"]
      else
        ENV["PATH"].split(File::PATH_SEPARATOR).product(%w[chrome google-chrome chromium chromium-browser]).map do |path, binary|
          [path, binary].join(File::SEPARATOR)
        end
      end.find do |path|
        File.executable?(path) && !File.directory?(path)
      end.tap do |path|
        raise Error, "couldn't find chrome" unless path
        stdout, status = Open3.capture2 path, "--version"
        raise Error, "couldn't start chrome" unless status.success?
        version = /(?<major>\d+)(?:\.\d+)*/.match stdout
        raise Error, "couldn't start chrome" unless version
        raise Error, "chrome version #{MIN_VERSION} or higher required" if version[:major].to_i < MIN_VERSION
      end
    end

    def self.rmdir(tmp)
      Proc.new do
        FileUtils.remove_entry tmp
      rescue SystemCallError
      end
    end

    def self.kill(pid, *pipes)
      Proc.new do
        if windows?
          *, status = Open3.capture2e *%W[taskkill /f /t /pid #{pid}]
          Process.kill "KILL", pid unless status.success?
        else
          Timeout.timeout(TIMEOUT_KILL, Error) do
            Process.kill "-USR1", Process.getpgid(pid)
            Process.wait pid
          rescue Error
            Process.kill "-KILL", Process.getpgid(pid)
            Process.wait pid
          end
        end
      rescue Errno::ESRCH, Errno::ECHILD
      ensure
        pipes.each(&:close)
      end
    end

    def close
      Chrome.kill(@pid, @input, @output).call
      Chrome.rmdir(@data_dir).call
      ObjectSpace.undefine_finalizer self
    end

    def self.with_browser(url, **opts, &block)
      browser = new url, **opts
      block.call browser
    ensure
      browser&.close
    end

    def initialize(url, width: 800, height: 600, background: { r: 0, g: 0, b: 0, a: 0 }, args: [])
      @id, @data_dir = 0, Dir.mktmpdir("nswtopo_headless_chrome_")
      ObjectSpace.define_finalizer self, Chrome.rmdir(@data_dir)

      defaults = %W[
        --disable-background-networking
        --disable-component-extensions-with-background-pages
        --disable-component-update
        --disable-default-apps
        --disable-extensions
        --disable-features=site-per-process,Translate
        --disable-lcd-text
        --disable-renderer-backgrounding
        --force-color-profile=srgb
        --force-device-scale-factor=1
        --headless=new
        --hide-scrollbars
        --no-default-browser-check
        --no-first-run
        --no-startup-window
        --remote-debugging-pipe=JSON
        --use-mock-keychain
        --user-data-dir=#{@data_dir}
      ]
      defaults << "--disable-gpu" if Config["gpu"] == false

      input, @input, @output, output = *IO.pipe, *IO.pipe
      input.nonblock, output.nonblock = false, false
      @input.sync = true

      @pid = Process.spawn Chrome.path, *defaults, *args, 1 => File::NULL, 2 => File::NULL, 3 => input, 4 => output, :pgroup => Chrome.windows? ? nil : true
      ObjectSpace.define_finalizer self, Chrome.kill(@pid, @input, @output)
      input.close; output.close

      target_id = command("Target.createTarget", url: url).fetch("targetId")
      @session_id = command("Target.attachToTarget", targetId: target_id, flatten: true).fetch("sessionId")
      command "Page.enable"
      wait "Page.loadEventFired", timeout: TIMEOUT_LOADEVENT
      command "Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: false
      command "Emulation.setDefaultBackgroundColorOverride", color: background
      @node_id = command("DOM.getDocument").fetch("root").fetch("nodeId")
    rescue SystemCallError
      raise Error, "couldn't start chrome"
    rescue KeyError
      raise Error
    end

    def send(**message)
      message.merge! sessionId: @session_id if @session_id
      @input.write message.to_json, ?\0
    end

    def messages
      Enumerator.produce do
        json = @output.readline(?\0).chomp(?\0)
        JSON.parse(json).tap do |message|
          raise Error if message["error"]
          raise Error if message["method"] == "Target.detachedFromTarget"
        end
      rescue JSON::ParserError, EOFError
        raise Error
      end
    end

    def wait(event, timeout: nil)
      Timeout.timeout(timeout) do
        messages.find do |message|
          message["method"] == event
        end
      end
    rescue Timeout::Error
      raise Error
    end

    def command(method, timeout: TIMEOUT_COMMAND, **params)
      send id: @id += 1, method: method, params: params
      Timeout.timeout(timeout) do
        messages.find do |message|
          message["id"] == @id
        end
      end.fetch("result")
    rescue Timeout::Error, KeyError
      raise Error
    end

    def screenshot(png_path)
      data = command("Page.captureScreenshot", timeout: TIMEOUT_SCREENSHOT).fetch("data")
      png_path.binwrite Base64.decode64(data)
    rescue KeyError
      raise Error
    end

    def print_to_pdf(pdf_path)
      data = command("Page.printToPDF", timeout: nil, preferCSSPageSize: true).fetch("data")
      pdf_path.binwrite Base64.decode64(data)
    rescue KeyError
      raise Error
    end

    def query_selector_node_id(selector)
      command("DOM.querySelector", selector: selector, nodeId: @node_id).fetch("nodeId")
    rescue KeyError
      raise Error
    end

    class Node
      def initialize(browser, selector)
        @browser, @node_id = browser, browser.query_selector_node_id(selector)
      end

      def [](name)
        @browser.command("DOM.getAttributes", nodeId: @node_id).fetch("attributes").each_slice(2).to_h.fetch(name.to_s)
      rescue KeyError
        raise Error
      end

      def []=(name, value)
        if value.nil?
          @browser.command "DOM.removeAttribute", nodeId: @node_id, name: name
        else
          @browser.command "DOM.setAttributeValue", nodeId: @node_id, name: name, value: value
        end
      end

      def value=(value)
        @browser.command "DOM.setNodeValue", nodeId: @node_id + 1, value: value
      end

      def width
        @browser.command("DOM.getBoxModel", nodeId: @node_id).fetch("model").fetch("content").each_slice(2).map(&:first).minmax.reverse.inject(&:-)
      rescue KeyError
        raise Error
      end
    end

    def query_selector(selector)
      Node.new self, selector
    end
  end
end

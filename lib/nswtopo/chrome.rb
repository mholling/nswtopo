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
        ["C:/Program Files/Google/Chrome/Application/chrome.exe", "C:/Program Files/Google/Chrome Dev/Application/chrome.exe"]
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

    def self.with_browser(*args, &block)
      new(*args).tap(&block).close
    end

    def initialize(*args, url)
      @id, @data_dir = 0, Dir.mktmpdir("nswtopo_headless_chrome_")
      ObjectSpace.define_finalizer self, Chrome.rmdir(@data_dir)

      defaults = %W[
        --default-background-color=00000000
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
    rescue SystemCallError
      raise Error, "couldn't start chrome"
    rescue KeyError
      raise Error
    end

    def send(**message)
      message.merge!(id: @id += 1, sessionId: @session_id).compact!
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
      send method: method, params: params
      Timeout.timeout(timeout) do
        messages.find do |message|
          message["id"] == @id
        end
      end.fetch("result")
    rescue Timeout::Error, KeyError
      raise Error
    end

    def evaluate(expression)
      command("Runtime.evaluate", expression: expression, returnByValue: true).fetch("result").tap do |result|
        raise Error if result["subtype"] == "error"
      end.fetch("value", nil)
    rescue KeyError
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
  end
end

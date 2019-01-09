module NSWTopo
  module Safely
    def safely(message = nil)
      yield
    rescue Interrupt => interrupt
      warn "\r\e[K#{message}" if message
      retry
    ensure
      raise interrupt if interrupt
    end
  end
end

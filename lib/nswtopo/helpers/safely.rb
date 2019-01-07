module NSWTopo
  module Safely
    def safely(message = nil)
      yield
    rescue Interrupt => interrupt
      warn "\r\033[K#{message}" if message
      retry
    ensure
      raise interrupt if interrupt
    end
  end
end

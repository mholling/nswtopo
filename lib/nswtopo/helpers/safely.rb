module NSWTopo
  module Safely
    include Log
    def safely(message = nil)
      yield
    rescue Interrupt => interrupt
      log_warn message if message
      retry
    ensure
      raise interrupt if interrupt
    end
  end
end

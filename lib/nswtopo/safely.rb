module NSWTopo
  module Safely
    include Log
    def safely(message)
      yield
    rescue Interrupt => interrupt
      log_warn message
      retry
    ensure
      raise interrupt if interrupt
    end
  end
end

module NSWTopo
  module Safely
    def safely(message = nil)
      yield
    rescue Interrupt => interrupt
      warn FAILURE % message if message
      retry
    ensure
      raise interrupt if interrupt
    end
  end
end

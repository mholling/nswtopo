module NSWTopo
  module Log
    SUCCESS = $stdout.tty? ? "\r\e[2K\e[32mnswtopo:\e[0m %s" : "nswtopo: %s"
    FAILURE = $stderr.tty? ? "\r\e[2K\e[31mnswtopo:\e[0m %s" : "nswtopo: %s"
    NEUTRAL = $stdout.tty? ? "\r\e[2Knswtopo: %s" : "nswtopo: %s"
    UPDATE  = "\r\e[2K%s"

    def log_success(message)
      puts SUCCESS % message
    end

    def log_neutral(message)
      puts NEUTRAL % message
    end

    def log_update(message)
      print UPDATE % message if $stdout.tty?
    end

    def log_warn(message)
      warn FAILURE % message
    end

    def log_abort(message)
      abort FAILURE % message
    end
  end
end

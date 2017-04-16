module InParallel
  CORES = Etc.nprocessors rescue 1
  
  def in_parallel
    processes = Set.new
    begin
      begin
        pid = Timeout.timeout(60) { Process.wait }
        processes.delete pid
      rescue Timeout::Error
      end if processes.any?
      begin
        while processes.length < CORES
          element = self.next
          processes << Process.fork { yield element }
        end
      rescue StopIteration
      end
    end while processes.any?
    rewind
  end
end

Enumerator.send :include, InParallel

module NSWTopo
  module Zip
    def zip(directory, archive)
      Enumerator.new do |yielder|
        yielder << ->(dir) { OS.zip "-r", archive.expand_path, *Pathname.glob('*') }
        yielder << ->(dir) { OS.send "7z", "a", "-tzip", "-r", archive.expand_path, *Pathname.glob('*') }
        raise "no zip utility installed"
      end.each do |zip|
        Dir.chdir(directory, &zip)
        break
      rescue OS::Missing
      end
    end
  end
end

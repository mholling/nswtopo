class Dir
  def self.mktmppath
    mktmpdir do |path|
      yield Pathname.new(path)
    end
  end
end

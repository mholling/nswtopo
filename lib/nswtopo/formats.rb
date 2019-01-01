require_relative 'formats/svg'
require_relative 'formats/png'
# require_relative 'formats/tif'
# require_relative 'formats/jpg'
# require_relative 'formats/kmz'
# require_relative 'formats/mbtiles'
# require_relative 'formats/zip'
# require_relative 'formats/pdf'
# require_relative 'formats/psd'
# require_relative 'formats/prj'
# TODO: prj not needed, just write it when --worldfile selected?

module NSWTopo::Formats
  def self.each(&block)
    modules = constants.map(&method(:const_get)).grep(Module).each
    block_given? ? tap { modules.each(&block) } : modules
  end
  extend Enumerable

  def self.included(mod)
    mod.include *self
  end

  def self.===(ext)
    map(&:ext).any?(ext)
  end

  each do |format|
    def format.ext
      name.split("::").last.downcase
    end
  end
end

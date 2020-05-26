require_relative 'commands/add'
require_relative 'commands/layers'
require_relative 'commands/config'
require_relative 'commands/scrape'
require_relative 'commands/inspect'

module NSWTopo
  def init(archive, options)
    puts Map.init(archive, options)
  end

  def info(archive, options)
    raise OptionParser::InvalidArgument, "one output option only" if options.slice(:json, :proj).length > 1
    puts Map.load(archive).info(options)
  end

  def delete(archive, *names, options)
    map = Map.load archive
    names.map do |name|
      Layer.sanitise name
    end.uniq.map do |name|
      name[?*] ? %r[^#{name.gsub(?., '\.').gsub(?*, '.*')}$] : name
    end.tap do |names|
      map.delete *names
    end
  end

  def render(archive, *formats, options)
    overwrite = options.delete :overwrite
    formats << "svg" if formats.empty?
    formats.map do |format|
      Pathname(Formats === format ? "#{archive.basename}.#{format}" : format)
    end.uniq.each do |path|
      format = path.extname.delete_prefix(?.)
      raise "unrecognised format: #{path}" if format.empty?
      raise "unrecognised format: #{format}" unless Formats === format
      raise "file already exists: #{path}" if path.exist? && !overwrite
      raise "non-existent directory: #{path.parent}" unless path.parent.directory?
    end.tap do |paths|
      Map.load(archive).render *paths, options
    end
  end
end

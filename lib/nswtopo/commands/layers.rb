module NSWTopo
  def layers(state: nil)
    paths = layer_dirs.grep_v(Pathname.pwd).flat_map do |directory|
      Array(state).inject(directory, &:/).glob("*")
    end.sort
    log_warn "no layers installed" if paths.none?

    TreeIndenter.new(paths) do |paths|
      paths.filter_map do |path|
        case
        when path.glob("**/*.yml").any?
          [path.basename.sub_ext(""), path.children.sort]
        when path.sub_ext("").directory?
        when path.extname == ".yml"
          path.basename.sub_ext("")
        end
      end
    end.each do |indents, name|
      puts [*indents, name].join
    end
  end
end

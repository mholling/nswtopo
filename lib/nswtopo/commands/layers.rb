module NSWTopo
  def layers(state: nil, indent: "")
    layer_dirs.grep_v(Pathname.pwd).flat_map do |directory|
      Array(state).inject(directory, &:/).glob("*")
    end.sort.each do |path|
      case
      when path.directory?
        next if path.glob("**/*.yml").none?
        puts [indent, path.basename.sub_ext("")].join
        layers state: [*state, path.basename], indent: "  " + indent
      when path.sub_ext("").directory?
      when path.extname == ".yml"
        puts [indent, path.basename.sub_ext("")].join
      end
    end.tap do |paths|
      log_warn "no layers installed" if paths.none?
    end
  end
end

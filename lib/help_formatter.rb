class HelpFormatter < RDoc::Markup::ToAnsi
  def initialize(ansi)
    @ansi = ansi
    super()
    @headings.clear
    return unless @ansi
    @headings[1] = ["\e[1m", "\e[m"] # bold
    @headings[2] = ["\e[4m", "\e[m"] # underline
    @headings[3] = ["\e[3m", "\e[m"] # italic
  end

  def init_tags
    return unless @ansi
    add_tag :BOLD, "\e[1m", "\e[m" # bold
    add_tag :EM,   "\e[3m", "\e[m" # italic
    add_tag :TT,   "\e[3m", "\e[m" # italic
  end

  def accept_list_item_start(list_item)
    @indent += 2
    super
    @res.pop if @res.last == ?\n
    @indent -= 2
  end

   def accept_verbatim(verbatim)
    indent = ?\s * (@indent + (@ansi ? 2 : 4))
    verbatim.parts.map(&:each_line).flat_map(&:entries).each.with_index do |line, index|
      case
      when !@ansi
        @res << indent << line
      when line.start_with?("$ ")
        @res << indent << "\e[90m$\e[;3m " << line[2..-1] << "\e[m"
      else
        @res << indent << "\e[90m> " << line << "\e[m"
      end
    end
    @res << ?\n
  end

  def accept_heading(heading)
    @indent += 2 unless heading.level == 1
    super
    @indent -= 2 unless heading.level == 1
  end

  def accept_paragraph(paragraph)
    @indent += 2
    text = paragraph.text.tr_s(?\r, ?\s).tr_s(?\n, ?\s)
    wrap attributes text
    @indent -= 2
    @res << ?\n
  end

  def start_accepting
    super
    @res = @ansi ? ["\e[0m"] : []
  end
end

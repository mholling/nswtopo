module NSWTopo
  class TreeIndenter
    def initialize(items, parts = nil, &block)
      @enum = Enumerator.new do |yielder|
        next unless items
        grouped = block ? block.(items) : items
        grouped.each.with_index do |(item, group), index|
          *new_parts, last_part = parts
          case last_part
          when "├─ " then new_parts << "│  "
          when "└─ " then new_parts << "   "
          end
          new_parts << case index
          when grouped.size - 1 then "└─ "
          else                       "├─ "
          end if parts
          yielder << [new_parts, item]
          TreeIndenter.new(group, new_parts, &block).inject(yielder, &:<<)
        end
      end
    end

    extend Forwardable
    include Enumerable
    delegate :each => :@enum
  end
end

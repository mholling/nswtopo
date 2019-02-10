class AVLTree
  include Enumerable
  attr_accessor :value, :left, :right, :height

  def initialize(&block)
    empty!
  end

  def empty?
    @value.nil?
  end

  def empty!
    @value, @left, @right, @height = nil, nil, nil, 0
  end

  def leaf?
    [@left, @right].all?(&:empty?)
  end

  def replace_with(node)
    @value, @left, @right, @height = node.value, node.left, node.right, node.height
  end

  def balance
    empty? ? 0 : @left.height - @right.height
  end

  def update_height
    @height = empty? ? 0 : [@left, @right].map(&:height).max + 1
  end

  def first_node
    empty? || @left.empty? ? self : @left.first_node
  end

  def last_node
    empty? || @right.empty? ? self : @right.last_node
  end

  def ancestors(node)
    node.empty? ? [] : case [@value, @value.object_id] <=> [node.value, node.value.object_id]
    when +1 then [*@left.ancestors(node), self]
    when  0 then []
    when -1 then [*@right.ancestors(node), self]
    end
  end

  def rotate_left
    a, b, c, v, @value = @left, @right.left, @right.right, @value, @right.value
    @left = @right
    @left.value, @left.left, @left.right, @right = v, a, b, c
    [@left, self].each(&:update_height)
  end

  def rotate_right
    a, b, c, v, @value = @left.left, @left.right, @right, @value, @left.value
    @right = @left
    @left.value, @left, @right.left, @right.right = v, a, b, c
    [@right, self].each(&:update_height)
  end

  def rebalance
    update_height
    case balance
    when +2
      @left.rotate_left if @left.balance == -1
      rotate_right
    when -2
      @right.rotate_right if @right.balance == 1
      rotate_left
    end unless empty?
  end

  def insert(value)
    if empty?
      @value, @left, @right = value, AVLTree.new, AVLTree.new
    else
      case [@value, @value.object_id] <=> [value, value.object_id]
      when +1 then @left.insert value
      when  0 then @value = value
      when -1 then @right.insert value
      end
    end
    rebalance
  end
  alias << insert

  def merge(values)
    values.each { |value| insert value }
    self
  end

  def delete(value)
    case [@value, @value.object_id] <=> [value, value.object_id]
    when +1 then @left.delete value
    when 0
      @value.tap do
        case
        when leaf? then empty!
        when @left.empty?
          node = @right.first_node
          @value = node.value
          node.replace_with node.right
          ancestors(node).each(&:rebalance) unless node.empty?
        else
          node = @left.last_node
          @value = node.value
          node.replace_with node.left
          ancestors(node).each(&:rebalance) unless node.empty?
        end
      end
    when -1 then @right.delete value
    end.tap { rebalance } unless empty?
  end

  def pop
    delete first_node.value unless empty?
  end

  def each(&block)
    unless empty?
      @left.each &block
      block.call @value
      @right.each &block
    end
  end
end

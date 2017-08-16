module Buffer
  include StraightSkeleton

  def inset(closed, margin, options = {})
    Nodes.new(self, closed).progress(+margin, options).readout
  end

  def outset(closed, margin, options = {})
    Nodes.new(self, closed).progress(-margin, options).readout
  end

  def offset(closed, *margins, options)
    margins.inject Nodes.new(self, closed) do |nodes, margin|
      nodes.progress(+margin, options)
    end.readout
  end

  def buffer(closed, margin, overshoot = margin)
    if closed
      Nodes.new(self, closed).progress(-margin-overshoot).progress(+overshoot, "splits" => false).readout
    else
      Nodes.new(self + map(&:reverse), closed).progress(+margin+overshoot).progress(-overshoot, "splits" => false).readout
    end
  end

  def smooth(margin, cutoff = nil)
    Nodes.new(self, false).progress(+margin).progress(-2 * margin, "cutoff" => cutoff).progress(+margin, "cutoff" => cutoff).readout
  end
end

Array.send :include, Buffer

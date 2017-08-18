module Buffer
  include StraightSkeleton

  def inset(margin, options = {})
    Nodes.new(self).progress(+margin, options).readout
  end

  def outset(margin, options = {})
    Nodes.new(self).progress(-margin, options).readout
  end

  def offset(*margins, options)
    margins.inject Nodes.new(self) do |nodes, margin|
      nodes.progress(+margin, options)
    end.readout
  end

  def buffer(closed, margin, overshoot = margin)
    if closed
      Nodes.new(self).progress(-margin-overshoot).progress(+overshoot).readout
    else
      Nodes.new(self + map(&:reverse)).progress(+margin+overshoot).progress(-overshoot).readout
    end
  end

  def smooth(margin, cutoff = nil)
    Nodes.new(self).progress(+margin).progress(-2 * margin, "cutoff" => cutoff).progress(+margin, "cutoff" => cutoff).readout
  end
end

Array.send :include, Buffer

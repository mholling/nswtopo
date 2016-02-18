#!/usr/bin/env ruby

# Copyright 2011-2015 Matthew Hollingworth
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'uri'
require 'net/http'
require 'rexml/document'
require 'rexml/formatters/pretty'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require 'pathname'
require 'rbconfig'
require 'json'
require 'base64'
require 'open-uri'
require 'set'

# %w[uri net/http rexml/document rexml/formatters/pretty tmpdir yaml fileutils pathname rbconfig json base64 open-uri].each { |file| require file }

GITHUB_SOURCES = "https://github.com/mholling/nswtopo/raw/master/sources/"
NSWTOPO_VERSION = "1.1.6"

class REXML::Element
  alias_method :unadorned_add_element, :add_element
  def add_element(name, attrs = {})
    unadorned_add_element(name, attrs).tap do |element|
      yield element if block_given?
    end
  end
end

module REXML::Functions
  def self.ends_with(string, test)
    string(string).rindex(string(test)) == string(string).length - string(test).length
  end
end

module HashHelpers
  def deep_merge(hash)
    hash.inject(self.dup) do |result, (key, value)|
      result.merge(key => result[key].is_a?(Hash) && value.is_a?(Hash) ? result[key].deep_merge(value) : value)
    end
  end
  
  def deep_merge!(hash)
    hash.each do |key, value|
      self[key].is_a?(Hash) && value.is_a?(Hash) ? self[key].deep_merge!(value) : self[key] = value
    end
    self
  end

  def to_query
    URI.escape reject { |key, value| value.nil? }.map { |key, value| "#{key}=#{value}" }.join(?&)
  end
end
Hash.send :include, HashHelpers

class Dir
  def self.mktmppath
    mktmpdir do |path|
      yield Pathname.new(path)
    end
  end
end

module Enumerable
  def recover(*exceptions)
    Enumerator.new do |yielder|
      each do |element|
        begin
          yielder.yield element
        rescue *exceptions => e
          $stderr.puts "\nError: #{e.message}"
          next
        end
      end
    end
  end
end

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
    [ @left, @right ].all?(&:empty?)
  end
  
  def replace_with(node)
    @value, @left, @right, @height = node.value, node.left, node.right, node.height
  end
  
  def balance
    empty? ? 0 : @left.height - @right.height
  end
  
  def update_height
    @height = empty? ? 0 : [ @left, @right ].map(&:height).max + 1
  end
  
  def first_node
    empty? || @left.empty? ? self : @left.first_node
  end
  
  def last_node
    empty? || @right.empty? ? self : @right.last_node
  end
  
  def ancestors(node)
    node.empty? ? [] : case @value <=> node.value
    when +1 then [ *@left.ancestors(node), self ]
    when  0 then [ ]
    when -1 then [ *@right.ancestors(node), self ]
    end
  end
  
  def rotate_left
    a, b, c, v, @value = @left, @right.left, @right.right, @value, @right.value
    @left = @right
    @left.value, @left.left, @left.right, @right = v, a, b, c
    [ @left, self ].each(&:update_height)
  end
  
  def rotate_right
    a, b, c, v, @value = @left.left, @left.right, @right, @value, @left.value
    @right = @left
    @left.value, @left, @right.left, @right.right = v, a, b, c
    [ @right, self ].each(&:update_height)
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
      case @value <=> value
      when +1 then @left.insert value
      when  0 then @value = value
      when -1 then @right.insert value
      end
    end
    rebalance
  end
  alias << insert
  
  def delete(value)
    case @value <=> value
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

module StraightSkeleton
  module Node
    attr_reader :point, :travel, :neighbours, :edges, :whence, :original
    
    def remove!
      @active.delete self
    end
    
    def active?
      @active.include? self
    end
    
    def terminal?
      @neighbours.one?
    end
    
    def headings
      @headings ||= @edges.map do |edge|
        edge.map(&:point).difference.normalised.perp if edge
      end
    end
    
    def heading
      @heading ||= headings.compact.inject(&:plus).normalised
    end
    
    def secant
      @secant ||= 1.0 / headings.compact.first.dot(heading)
    end
    
    def edge
      [ self, @neighbours[1] ] if @neighbours[1]
    end
    
    def collapses
      @neighbours.map.with_index do |neighbour, index|
        next unless neighbour
        cos = Math::cos(neighbour.heading.angle - heading.angle)
        next if cos*cos == 1.0
        distance = neighbour.heading.times(cos).minus(heading).dot(@point.minus neighbour.point) / (1.0 - cos*cos)
        next if distance < 0 || distance.nan?
        travel = @travel + distance / secant
        next if @limit && travel > @limit
        Collapse.new @active, @candidates, @limit, heading.times(distance).plus(@point), travel, [ neighbour, self ].rotate(index)
      end.compact.sort.take(1)
    end
  end
  
  module InteriorNode
    include Node
    
    def <=>(other)
      @travel <=> other.travel
    end
    
    def insert!
      @edges = @neighbours.map.with_index do |neighbour, index|
        next unless neighbour
        neighbour.neighbours[1-index] = self
        neighbour.edges[1-index]
      end
      @active << self
      [ self, *@neighbours ].compact.map(&:collapses).flatten.each do |candidate|
        @candidates << candidate
      end
    end
    
    def process
      return unless viable?
      replace! do |node, index = 0|
        node.remove!
        yield [ node, self ].rotate(index) if block_given?
      end
    end
  end
  
  class Vertex
    include Node
    
    def initialize(active, candidates, limit, point, index)
      @original, @neighbours, @active, @candidates, @limit, @whence, @point, @travel = self, [ nil, nil ], active, candidates, limit, Set[index], point, 0
    end
    
    def add
      @edges = @neighbours.map.with_index do |neighbour, index|
        [ neighbour, self ].rotate(index) if neighbour
      end
      @active << self
    end
    
    def splits
      return [ ] if terminal? || headings.inject(&:cross) >= 0
      @active.map(&:edge).compact.map do |edge|
        e0, e1 = edge.map(&:point)
        next if e0 == @point || e1 == @point
        h0, h1 = edge.map(&:heading)
        direction = e1.minus(e0).normalised.perp
        travel = direction.dot(@point.minus e0) / (1 - secant * heading.dot(direction))
        next if travel < 0 || travel.nan?
        next if @limit && travel > @limit
        point = heading.times(secant * travel).plus(@point)
        next if point.minus(e0).dot(direction) < 0
        next if point.minus(e0).cross(h0) < 0
        next if point.minus(e1).cross(h1) > 0
        Split.new @active, @candidates, @limit, point, travel, self, edge
      end.compact.sort.take(1)
    end
    
    class << self
      { :polygon => :ring, :lines => :segments }.each do |name, pairs|
        define_method(name) do |data, limit = nil|
          active, candidates = Set.new, AVLTree.new
          data.each.with_index do |points, index|
            nodes = points.send(pairs).reject do |segment|
              segment.inject(&:==)
            end.map(&:first).tap do |pruned|
              pruned << points.last if pairs == :segments
            end.map do |point|
              Vertex.new active, candidates, limit, point, index
            end
            nodes.send(pairs).each do |edge|
              edge[1].neighbours[0], edge[0].neighbours[1] = edge
            end
            nodes.each(&:add).map do |node|
              node.splits + node.collapses
            end.flatten.each do |candidate|
              candidates << candidate
            end
          end
          [ active, candidates ]
        end
      end
    end
    
    def self.skeleton(data)
      active, candidates = Vertex.polygon(data)
      Enumerator.new do |yielder|
        while candidate = candidates.pop
          candidate.process do |nodes|
            yielder << nodes.map(&:original)
          end
        end
      end
    end
    
    def self.inset(data, vertices, travel)
      active, candidates = Vertex.send(vertices, data, travel)
      while candidate = candidates.pop
        candidate.process
      end
      result = [ ]
      while active.any?
        nodes = [ active.first ]
        while node = nodes.last.neighbours[1] and node != nodes.first
          nodes << node
        end
        result << nodes.each(&:remove!).map do |node|
          node.heading.times((travel - node.travel) * node.secant).plus(node.point)
        end
      end
      result
    end
  end
  
  class Collapse
    include InteriorNode
    
    def initialize(active, candidates, limit, point, travel, sources)
      @original, @active, @candidates, @limit, @point, @travel, @sources = self, active, candidates, limit, point, travel, sources
      @whence = @sources.map(&:whence).inject(&:|)
    end
    
    def viable?
      @sources.all?(&:active?)
    end
    
    def replace!(&block)
      @neighbours = [ @sources[0].neighbours[0], @sources[1].neighbours[1] ]
      @neighbours.inject(&:==) ? block.call(@neighbours[0]) : insert! if @neighbours.any?
      @sources.each(&block)
    end
  end
  
  class Split
    include InteriorNode
    
    def initialize(active, candidates, limit, point, travel, source, split)
      @original, @active, @candidates, @limit, @point, @travel, @sources, @split = self, active, candidates, limit, point, travel, [ source ], split
      @whence = [ source, *@split ].map(&:whence).inject(&:|)
    end
    
    def viable?
      return false unless @sources.all?(&:active?)
      @split = @active.map(&:edge).compact.select do |edge|
        edge[0].edges[1] == @split || edge[1].edges[0] == @split
      end.find do |edge|
        e0, e1 = edge.map(&:point)
        h0, h1 = edge.map(&:heading)
        next if point.minus(e0).cross(h0) < 0
        next if point.minus(e1).cross(h1) > 0
        true
      end
    end
    
    def split(index, &block)
      @neighbours = [ @sources[0].neighbours[index], @split[1-index] ].rotate index
      @neighbours.inject(&:==) ? block.call(@neighbours[0], @neighbours[0].is_a?(Collapse) ? 1 : 0) : insert! if @neighbours.any?
    end
    
    def replace!(&block)
      dup.split(0, &block)
      dup.split(1, &block)
      @sources.each(&block)
    end
  end
  
  def straight_skeleton
    Vertex.skeleton(self).map do |nodes|
      nodes.map(&:point)
    end
  end
  
  def centreline(margin_fraction = 0.25)
    ends   = Hash.new { |ends,   node|   ends[node] = [ ] }
    splits = Hash.new { |splits, node| splits[node] = [ ] }
    Vertex.skeleton(self).each do |node0, node1|
      case [ node0.class, node1.class ]
      when [ Split, Collapse ], [ Split, Split ]
        splits[node1] << [ node0, node1 ]
      when [ Collapse, Collapse ]
        splits.delete(node0).each do |path|
          splits[node1] << [ *path, node1 ]
        end if splits.key? node0
        ends.delete(node0).each do |path|
          ends[node1] << [ *path, node1 ]
        end if ends.key? node0
      when [ Vertex, Collapse ]
        ends[node1] << [ node0, node1 ]
      end
    end
    ends = ends.map do |node1, paths|
      paths.reject do |*nodes, node, node1|
        splits[node1].any? do |*nodes, node0, node1|
          node0 == node
        end if splits.key? node1
      end.group_by do |*nodes, node, node1|
        node
      end.map do |node, paths|
        paths.map do |path|
          path.map(&:point).segments.map(&:difference).map(&:norm).inject(0, &:+)
        end.zip(paths).max_by(&:first)
      end.sort_by(&:first).last(2).map(&:last)
    end
    neighbours = Hash.new { |neighbours, node| neighbours[node] = Set.new }
    paths, lengths = { }, { }
    [ ends, splits.values ].flatten(2).select(&:many?).each do |path|
      [ path, path.reverse ].each do |node0, *nodes, node1|
        neighbours[node0] << node1
        paths.store [ node0, node1 ], [ *nodes, node1]
        lengths.store [ node0, node1 ], [ node0, *nodes, node1 ].map(&:point).segments.map(&:distance).inject(&:+)
      end
    end
    distances, centrelines = Hash.new(0), { }
    areas = map(&:signed_area)
    candidates = neighbours.keys.map do |point|
      [ [ point ], 0, Set[point] ]
    end
    while candidates.any?
      nodes, distance, visited = candidates.pop
      next if (neighbours[nodes.last] - visited).each do |node|
        candidates << [ [ *nodes, node ], distance + lengths.fetch([ nodes.last, node ]), visited.dup.add(node) ]
      end.any?
      index = nodes.map(&:whence).inject(&:|).find do |index|
        areas[index] > 0
      end
      distances[index], centrelines[index] = distance, nodes if index && distance > distances[index]
    end
    centrelines.values.map do |nodes|
      travel = nodes.map(&:travel).max
      paths.values_at(*nodes.segments).inject(nodes.take(1), &:+).chunk do |node|
        node.travel > margin_fraction * travel
      end.select(&:first).map(&:last).reject(&:one?).map do |nodes|
        nodes.map(&:point)
      end
    end.flatten(1)
  end
  
  def centrepoints(margin_fraction = 0.5)
    counts = Hash.new(0)
    peaks = Vertex.skeleton(self).map(&:last).each do |node|
      counts[node] += 1
    end.select do |node|
      counts[node] == 3
    end.sort_by(&:travel).reverse
    peaks.select do |node|
      node.travel > margin_fraction * peaks.first.travel
    end.map(&:point)
  end
  
  def buffer_polygon(margin)
    margin > 0 ? Vertex.inset(self, :polygon, margin) : map(&:reverse).buffer_polygon(-margin).map(&:reverse)
  end
  
  def buffer_lines(margin)
    Vertex.inset(self + map(&:reverse), :lines, margin.abs)
  end
end

class Array
  include StraightSkeleton
  
  def median
    sort[length / 2]
  end
  
  def mean
    empty? ? nil : inject(&:+) / length
  end
  
  def rotate_by(angle)
    cos = Math::cos(angle)
    sin = Math::sin(angle)
    [ self[0] * cos - self[1] * sin, self[0] * sin + self[1] * cos ]
  end

  def rotate_by!(angle)
    self[0], self[1] = rotate_by(angle)
  end
  
  def rotate_by_degrees(angle)
    rotate_by(angle * Math::PI / 180.0)
  end
  
  def rotate_by_degrees!(angle)
    self[0], self[1] = rotate_by_degrees(angle)
  end
  
  def plus(other)
    [ self, other ].transpose.map { |values| values.inject(:+) }
  end

  def minus(other)
    [ self, other ].transpose.map { |values| values.inject(:-) }
  end

  def dot(other)
    [ self, other ].transpose.map { |values| values.inject(:*) }.inject(:+)
  end
  
  def times(scalar)
    map { |value| value * scalar }
  end
  
  def angle
    Math::atan2 at(1), at(0)
  end

  def norm
    Math::sqrt(dot self)
  end
  
  def normalised
    times(1.0 / norm)
  end
  
  def proj(other)
    dot(other) / other.norm
  end
  
  def one_or_many(&block)
    case first
    when Numeric then block.(self)
    else map(&block)
    end
  end
  
  def many?
    length > 1
  end
  
  def segments
    self[0..-2].zip self[1..-1]
  end
  
  def ring
    zip rotate
  end
  
  def difference
    last.minus first
  end
  
  def distance
    difference.norm
  end
  
  def along(fraction)
    self[1].times(fraction).plus self[0].times(1.0 - fraction)
  end
  
  def midpoint
    transpose.map(&:mean)
  end
  
  def cosines
    segments.map(&:difference).map(&:normalised).segments.map do |vectors|
      vectors.inject(&:dot)
    end
  end
  
  def perp
    [ -self[1], self[0] ]
  end
  
  def cross(other)
    perp.dot other
  end
  
  def perps
    ring.map(&:difference).map(&:perp)
  end
  
  def surrounds?(points)
    Enumerator.new do |yielder|
      points.each do |point|
        yielder << [ self, perps ].transpose.all? { |vertex, perp| point.minus(vertex).dot(perp) >= 0 }
      end
    end
  end
  
  def clip_points(hull)
    [ hull, hull.perps ].transpose.inject(self) do |result, (vertex, perp)|
      result.select { |point| point.minus(vertex).dot(perp) >= 0 }
    end
  end
  
  def clip_points!(hull)
    replace clip_points(hull)
  end
  
  def clip_lines(hull)
    [ hull, hull.perps ].transpose.inject(self) do |result, (vertex, perp)|
      result.inject([]) do |clipped, points|
        clipped + [ *points, points.last ].segments.inject([[]]) do |lines, segment|
          inside = segment.map { |point| point.minus(vertex).dot(perp) >= 0 }
          case
          when inside.all?
            lines.last << segment[0]
          when inside[0]
            lines.last << segment[0]
            lines.last << segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
          when inside[1]
            lines << [ ]
            lines.last << segment.along(vertex.minus(segment[0]).dot(perp) / segment.difference.dot(perp))
          end
          lines
        end
      end
    end.select(&:many?)
  end
  
  def clip_lines!(hull)
    replace clip_lines(hull)
  end
  
  def clip_polys(hull)
    [ hull, hull.perps ].transpose.inject(self) do |polygons, (vertex, perp)|
      polygons.inject([]) do |clipped, polygon|
        insides = polygon.map { |point| point.minus(vertex).dot(perp) >= 0 }
        case
        when insides.all? then clipped << polygon
        when insides.none?
        else
          outgoing = insides.ring.map.with_index.select { |inside, index| inside[0] && !inside[1] }.map(&:last)
           ingoing = insides.ring.map.with_index.select { |inside, index| !inside[0] && inside[1] }.map(&:last)
          pairs = [ outgoing, ingoing ].map do |indices|
            polygon.ring.map.with_index.to_a.values_at(*indices).map do |segment, index|
              [ segment.along(vertex.minus(segment[0]).dot(perp).to_f / segment.difference.dot(perp)), index ]
            end.sort_by do |intersection, index|
              [ vertex.minus(intersection).dot(perp.perp), index ]
            end
          end.transpose
          clipped << []
          while pairs.any?
            index ||= pairs[0][1][1]
            start ||= pairs[0][0][1]
            pair = pairs.min_by do |pair|
              intersections, indices = pair.transpose
              (indices[0] - index) % polygon.length
            end
            pairs.delete pair
            intersections, indices = pair.transpose
            while (indices[0] - index) % polygon.length > 0
              index += 1
              index %= polygon.length
              clipped.last << polygon[index]
            end
            clipped.last << intersections[0] << intersections[1]
            if index == start
              clipped << []
              index = start = nil
            else
              index = indices[1]
            end
          end
        end
        clipped.select(&:any?)
      end
    end
  end
  
  def clip_polys!(hull)
    replace clip_polys(hull)
  end
  
  def round(decimal_digits)
    one_or_many do |point|
      point.map { |value| value.round decimal_digits }
    end
  end
  
  def to_path_data(decimal_digits, *close)
    round(decimal_digits).inject do |memo, point|
      [ *memo, ?L, *point ]
    end.unshift(?M).push(*close).join(?\s)
  end
  
  def to_bezier(k, decimal_digits, *close)
    points = close.any? ? [ last, *self, first ] : [ first, *self, last ]
    midpoints = points.segments.map(&:midpoint)
    distances = points.segments.map(&:distance)
    offsets = midpoints.zip(distances).segments.map(&:transpose).map do |segment, distance|
      segment.along(distance.first / distance.inject(&:+))
    end.zip(self).map(&:difference)
    controls = midpoints.segments.zip(offsets).map do |segment, offset|
      segment.map { |point| [ point, point.plus(offset) ].along(k) }
    end.flatten(1).drop(1).round(decimal_digits).each_slice(2)
    drop(1).round(decimal_digits).zip(controls).map do |point, (control1, control2)|
      [ ?C, *control1, *control2, *point ]
    end.flatten.unshift(?M, *first.round(decimal_digits)).push(*close).join(?\s)
  end
  
  def convex_hull
    start = min_by(&:reverse)
    hull, remaining = partition { |point| point == start }
    remaining.sort_by do |point|
      [ point.minus(start).angle, point.minus(start).norm ]
    end.inject(hull) do |memo, p3|
      while memo.many? do
        p1, p2 = memo.last(2)
        (p3.minus p1).cross(p2.minus p1) < 0 ? break : memo.pop
      end
      memo << p3
    end
  end
  
  def signed_area
    0.5 * ring.map { |p1, p2| p1.cross p2 }.inject(&:+)
  end
  
  def centroid
    ring.map do |p1, p2|
      (p1.plus p2).times(p1.cross p2)
    end.inject(&:plus).times(1.0 / 6.0 / signed_area)
  end
  
  def smooth(arc_limit, iterations)
    iterations.times.inject(self) do |points|
      points.segments.segments.chunk do |segments|
        segments.map(&:difference).inject(&:cross) > 0
      end.map do |leftwards, pairs|
        arc_length = pairs.map(&:first).map(&:distance).inject(&:+)
        pairs.map do |segment1, segment2|
          arc_length < arc_limit ? segment1.first.plus(segment2.last).times(0.5) : segment1.last
        end
      end.flatten(1).unshift(points.first).push(points.last)
    end
  end
  
  def smooth!(*args)
    replace smooth(*args)
  end
  
  def densify(step, closed)
    (closed ? ring : segments).inject([]) do |memo, segment|
      memo += (0...1).step(step / segment.distance).map do |fraction|
        segment.along fraction
      end
    end.tap do |result|
      result << points.last unless closed
    end
  end
  
  def densify!(*args)
    replace densify(*args)
  end
  
  def between_critical_supports
    indices = [ at(0).map.with_index.min.last, at(1).map.with_index.max.last ]
    calipers = [ [ 0, -1 ], [ 0, 1 ] ]
    rotation = 0.0
    count = 0
    
    Enumerator.new do |yielder|
      while rotation <= 2 * Math::PI
        pairs, edges, vertices = zip(indices).map do |polygon, index|
          pair = polygon.values_at (index - 1) % polygon.length, (index + 1) % polygon.length
          edge = polygon.values_at index, (index + 1) % polygon.length
          [ pair, edge, polygon[index] ]
        end.transpose
        
        angle, which = edges.zip(calipers).map do |edge, caliper|
          vector = edge.difference.rotate_by(-rotation)
          Math::acos vector.dot(caliper) / vector.norm
        end.map.with_index.min
        
        perp = vertices.difference.perp
        comparisons = [ 1, -1 ].zip(pairs).map do |sign, pair|
          pair.map { |point| sign * point.minus(vertices.first).dot(perp) <=> 0 }
        end.flatten
        count += 1 if comparisons.inject(&:+).abs == 4
        
        yielder << edges.rotate(which) if count > 0
        break if count > 1
        
        rotation += angle
        indices[which] += 1
        indices[which] %= at(which).length
      end
    end
  end
  
  def disjoint?
    between_critical_supports.any?
  end
  
  def minimum_distance
    between_critical_supports.inject(nil) do |distance, edges|
      edge_vector = edges.first.difference
      vertex_vector = edges.map(&:first).difference
      vertex_dot_edge = vertex_vector.dot edge_vector
      if vertex_dot_edge <= 0 || vertex_dot_edge >= edge_vector.dot(edge_vector)
        [ *distance, vertex_vector.norm ].min
      else
        [ *distance, vertex_vector.proj(edge_vector.perp).abs ].min
      end
    end || 0
  end
  
  def overlaps(buffer = 0)
    axis = flatten(1).transpose.map { |values| values.max - values.min }.map.with_index.max.last
    events, tops, bots, results = AVLTree.new, [], [], []
    margin = [ buffer, 0 ]
    each.with_index do |hull, index|
      min, max = hull.map { |point| point.rotate axis }.minmax
      events << [ min.minus(margin), index, :start ]
      events << [ max.plus( margin), index, :stop  ]
    end
    events.each do |point, index, event|
      top, bot = at(index).transpose[1-axis].minmax
      case event
      when :start
        not_above = bots.select { |bot, other| bot >= top - buffer }.map(&:last)
        not_below = tops.select { |top, other| top <= bot + buffer }.map(&:last)
        (not_below & not_above).reject do |other|
          buffer.zero? ? values_at(index, other).disjoint? : values_at(index, other).minimum_distance > buffer
        end.each do |other|
          results << [ index, other ]
        end
        tops << [ top, index ]
        bots << [ bot, index ]
      when :stop
        tops.delete [ top, index ]
        bots.delete [ bot, index ]
      end
    end
    results
  end
  
  def principal_components
    centre = transpose.map(&:mean)
    deviations = map { |point| point.minus centre }.transpose
    a00, a01, a11 = [ [0, 0], [0, 1], [1, 1] ].map do |axes|
      deviations.values_at(*axes).transpose.map { |d1, d2| d1 * d2 }.inject(&:+)
    end
    eigenvalues = [ -1, +1 ].map do |sign|
      0.5 * (a00 + a11 + sign * Math::sqrt(a00**2 + 4 * a01**2 - 2 * a00 * a11 + a11**2))
    end
    eigenvectors = eigenvalues.reverse.map do |eigenvalue|
      [ a00 + a01 - eigenvalue, a11 + a01 - eigenvalue ]
    end
    eigenvalues.zip eigenvectors
  end
end

class String
  def in_two
    return split ?\n if match ?\n
    words = split ?\s
    (1...words.length).map do |index|
      [ words[0 ... index].join(?\s), words[index ... words.length].join(?\s) ]
    end.min_by do |lines|
      lines.map(&:length).max
    end || [ dup ]
  end
  
  def to_category
    gsub(/^\W+|\W+$/, '').gsub(/\W+/, ?-)
  end
end

module NSWTopo
  SEGMENT = ?.
  MM_DECIMAL_DIGITS = 4
  EARTH_RADIUS = 6378137.0
  
  WINDOWS = !RbConfig::CONFIG["host_os"][/mswin|mingw/].nil?
  OP = WINDOWS ? '(' : '\('
  CP = WINDOWS ? ')' : '\)'
  ZIP = WINDOWS ? "7z a -tzip" : "zip"
  DISCARD_STDERR = WINDOWS ? "2> nul" : "2>/dev/null"
  
  CONFIG = %q[---
name: map
scale: 25000
ppi: 300
rotation: 0
]
  
  module BoundingBox
    def self.minimum_bounding_box(points)
      polygon = points.convex_hull
      indices = [ [ :min_by, :max_by ], [ 0, 1 ] ].inject(:product).map do |min, axis|
        polygon.map.with_index.send(min) { |point, index| point[axis] }.last
      end
      calipers = [ [ 0, -1 ], [ 1, 0 ], [ 0, 1 ], [ -1, 0 ] ]
      rotation = 0.0
      candidates = []
  
      while rotation < Math::PI / 2
        edges = indices.map do |index|
          polygon[(index + 1) % polygon.length].minus polygon[index]
        end
        angle, which = [ edges, calipers ].transpose.map do |edge, caliper|
          Math::acos(edge.dot(caliper) / edge.norm)
        end.map.with_index.min_by { |angle, index| angle }
    
        calipers.each { |caliper| caliper.rotate_by!(angle) }
        rotation += angle
    
        break if rotation >= Math::PI / 2
    
        dimensions = [ 0, 1 ].map do |offset|
          polygon[indices[offset + 2]].minus(polygon[indices[offset]]).proj(calipers[offset + 1])
        end
    
        centre = polygon.values_at(*indices).map do |point|
          point.rotate_by(-rotation)
        end.partition.with_index do |point, index|
          index.even?
        end.map.with_index do |pair, index|
          0.5 * pair.map { |point| point[index] }.inject(:+)
        end.rotate_by(rotation)
    
        if rotation < Math::PI / 4
          candidates << [ centre, dimensions, rotation ]
        else
          candidates << [ centre, dimensions.reverse, rotation - Math::PI / 2 ]
        end
    
        indices[which] += 1
        indices[which] %= polygon.length
      end
  
      candidates.min_by { |centre, dimensions, rotation| dimensions.inject(:*) }
    end
  end

  module WorldFile
    def self.write(topleft, resolution, angle, path)
      path.open("w") do |file|
        file.puts  resolution * Math::cos(angle * Math::PI / 180.0)
        file.puts  resolution * Math::sin(angle * Math::PI / 180.0)
        file.puts  resolution * Math::sin(angle * Math::PI / 180.0)
        file.puts -resolution * Math::cos(angle * Math::PI / 180.0)
        file.puts topleft.first + 0.5 * resolution
        file.puts topleft.last - 0.5 * resolution
      end
    end
  end
  
  class GPS
    module GPX
      def waypoints
        Enumerator.new do |yielder|
          @xml.elements.each "/gpx//wpt" do |waypoint|
            coords = [ "lon", "lat" ].map { |name| waypoint.attributes[name].to_f }
            name = waypoint.elements["./name"]
            yielder << [ coords, name ? name.text : "" ]
          end
        end
      end
      
      def tracks
        Enumerator.new do |yielder|
          @xml.elements.each "/gpx//trk" do |track|
            list = track.elements.collect(".//trkpt") { |point| [ "lon", "lat" ].map { |name| point.attributes[name].to_f } }
            name = track.elements["./name"]
            yielder << [ list, name ? name.text : "" ]
          end
        end
      end
      
      def areas
        Enumerator.new { |yielder| }
      end
    end

    module KML
      def waypoints
        Enumerator.new do |yielder|
          @xml.elements.each "/kml//Placemark[.//Point/coordinates]" do |waypoint|
            coords = waypoint.elements[".//Point/coordinates"].text.split(',')[0..1].map(&:to_f)
            name = waypoint.elements["./name"]
            yielder << [ coords, name ? name.text : "" ]
          end
        end
      end
      
      def tracks
        Enumerator.new do |yielder|
          @xml.elements.each "/kml//Placemark[.//LineString//coordinates]" do |track|
            list = track.elements[".//LineString//coordinates"].text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) }
            name = track.elements["./name"]
            yielder << [ list, name ? name.text : "" ]
          end
          @xml.elements.each "/kml//Placemark//gx:Track" do |track|
            list = track.elements.collect("./gx:coord") { |coord| coord.text.split(?\s).take(2).map(&:to_f) }
            name = track.elements["ancestor::/Placemark[1]"].elements["name"]
            yielder << [ list, name ? name.text : "" ]
          end
        end
      end
      
      def areas
        Enumerator.new do |yielder|
          @xml.elements.each "/kml//Placemark[.//Polygon//coordinates]" do |polygon|
            list = polygon.elements[".//Polygon//coordinates"].text.split(' ').map { |triplet| triplet.split(',')[0..1].map(&:to_f) }
            name = polygon.elements["./name"]
            yielder << [ list, name ? name.text : "" ]
          end
        end
      end
    end

    def initialize(path)
      @xml = REXML::Document.new(path.read)
      case
      when @xml.elements["/gpx"] then class << self; include GPX; end
      when @xml.elements["/kml"] then class << self; include KML; end
      else raise BadGpxKmlFile.new(path.to_s)
      end
    rescue REXML::ParseException, Errno::ENOENT
      raise BadGpxKmlFile.new(path.to_s)
    end
  end
  
  class Projection
    def initialize(string)
      @string = string
    end
    
    %w[proj4 wkt wkt_simple wkt_noct wkt_esri mapinfo xml].map do |format|
      [ format, "@#{format}" ]
    end.map do |format, variable|
      define_method format do
        instance_variable_get(variable) || begin
          instance_variable_set variable, %x[gdalsrsinfo -o #{format} "#{@string}"].split(/['\r\n]+/).map(&:strip).join("")
        end
      end
    end
    
    alias_method :to_s, :proj4
    
    %w[central_meridian scale_factor].each do |parameter|
      define_method parameter do
        /PARAMETER\["#{parameter}",([\d\.]+)\]/.match(wkt) { |match| match[1].to_f }
      end
    end
    
    def self.utm(zone, south = true)
      new("+proj=utm +zone=#{zone}#{' +south' if south} +ellps=WGS84 +datum=WGS84 +units=m +no_defs")
    end
    
    def self.wgs84
      new("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")
    end
    
    def self.transverse_mercator(central_meridian, scale_factor)
      new("+proj=tmerc +lat_0=0.0 +lon_0=#{central_meridian} +k=#{scale_factor} +x_0=500000.0 +y_0=10000000.0 +ellps=WGS84 +datum=WGS84 +units=m")
    end
    
    def reproject_to(target, point_or_points)
      gdaltransform = %Q[gdaltransform -s_srs "#{self}" -t_srs "#{target}"]
      case point_or_points.first
      when Array
        point_or_points.map do |point|
          "echo #{point.join ?\s}"
        end.inject([]) do |(*echoes, last), echo|
          case
          when last && last.length + echo.length + gdaltransform.length < 2000 then [ *echoes, "#{last} && #{echo}" ]
          else [ *echoes, *last, echo ]
          end
        end.map do |echoes|
          %x[(#{echoes}) | #{gdaltransform}].each_line.map do |line|
            line.split(?\s)[0..1].map(&:to_f)
          end
        end.inject(&:+)
      else %x[echo #{point_or_points.join ?\s} | #{gdaltransform}].split(?\s)[0..1].map(&:to_f)
      end
    end
    
    def reproject_to_wgs84(point_or_points)
      reproject_to Projection.wgs84, point_or_points
    end
    
    def transform_bounds_to(target, bounds)
      reproject_to(target, bounds.inject(&:product)).transpose.map { |coords| [ coords.min, coords.max ] }
    end
    
    def self.utm_zone(coords, projection)
      projection.reproject_to_wgs84(coords).one_or_many do |longitude, latitude|
        (longitude / 6).floor + 31
      end
    end
    
    def self.in_zone?(zone, coords, projection)
      projection.reproject_to_wgs84(coords).one_or_many do |longitude, latitude|
        (longitude / 6).floor + 31 == zone
      end
    end
    
    def self.utm_hull(zone)
      longitudes = [ 31, 30 ].map { |offset| (zone - offset) * 6.0 }
      latitudes = [ -80.0, 84.0 ]
      longitudes.product(latitudes).values_at(0,2,3,1)
    end
  end
  
  class Map
    def initialize(config)
      @name, @scale = config.values_at("name", "scale")
      
      wgs84_points = case
      when config["zone"] && config["eastings"] && config["northings"]
        utm = Projection.utm(config["zone"])
        utm.reproject_to_wgs84 config.values_at("eastings", "northings").inject(:product)
      when config["longitudes"] && config["latitudes"]
        config.values_at("longitudes", "latitudes").inject(:product)
      when config["size"] && config["zone"] && config["easting"] && config["northing"]
        utm = Projection.utm(config["zone"])
        [ utm.reproject_to_wgs84(config.values_at("easting", "northing")) ]
      when config["size"] && config["longitude"] && config["latitude"]
        [ config.values_at("longitude", "latitude") ]
      when config["bounds"]
        bounds_path = Pathname.new(config["bounds"]).expand_path
        gps = GPS.new bounds_path
        polygon = gps.areas.first
        config["margin"] = 15 unless (gps.waypoints.none? && gps.tracks.none?) || config.key?("margin")
        polygon ? polygon.first : gps.tracks.any? ? gps.tracks.to_a.transpose.first.inject(&:+) : gps.waypoints.to_a.transpose.first
      else
        abort "Error: map extent must be provided as a bounds file, zone/eastings/northings, zone/easting/northing/size, latitudes/longitudes or latitude/longitude/size"
      end
      
      @projection_centre = wgs84_points.transpose.map { |coords| 0.5 * (coords.max + coords.min) }
      @projection = config["utm"] ?
        Projection.utm(config["zone"] || Projection.utm_zone(@projection_centre, Projection.wgs84)) :
        Projection.transverse_mercator(@projection_centre.first, 1.0)
      
      @declination = config["declination"]["angle"] if config["declination"]
      config["rotation"] = -declination if config["rotation"] == "magnetic"
      
      if config["size"]
        sizes = config["size"].split(/[x,]/).map(&:to_f)
        abort "Error: invalid map size: #{config["size"]}" unless sizes.length == 2 && sizes.all? { |size| size > 0.0 }
        @extents = sizes.map { |size| size * 0.001 * scale }
        @rotation = config["rotation"]
        abort "Error: cannot specify map size and auto-rotation together" if @rotation == "auto"
        abort "Error: map rotation must be between +/-45 degrees" unless @rotation.abs <= 45
        @centre = reproject_from_wgs84 @projection_centre
      else
        puts "Calculating map bounds..."
        bounding_points = reproject_from_wgs84 wgs84_points
        if config["rotation"] == "auto"
          @centre, @extents, @rotation = BoundingBox.minimum_bounding_box(bounding_points)
          @rotation *= 180.0 / Math::PI
        else
          @rotation = config["rotation"]
          abort "Error: map rotation must be between -45 and +45 degrees" unless rotation.abs <= 45
          @centre, @extents = bounding_points.map do |point|
            point.rotate_by_degrees(-rotation)
          end.transpose.map do |coords|
            [ coords.max, coords.min ]
          end.map do |max, min|
            [ 0.5 * (max + min), max - min ]
          end.transpose
          @centre.rotate_by_degrees!(rotation)
        end
        @extents.map! { |extent| extent + 2 * config["margin"] * 0.001 * @scale } if config["margin"]
      end

      enlarged_extents = [ @extents[0] * Math::cos(@rotation * Math::PI / 180.0) + @extents[1] * Math::sin(@rotation * Math::PI / 180.0).abs, @extents[0] * Math::sin(@rotation * Math::PI / 180.0).abs + @extents[1] * Math::cos(@rotation * Math::PI / 180.0) ]
      @bounds = [ @centre, enlarged_extents ].transpose.map { |coord, extent| [ coord - 0.5 * extent, coord + 0.5 * extent ] }
    rescue BadGpxKmlFile => e
      abort "Error: invalid bounds file #{e.message}"
    end
    
    attr_reader :name, :scale, :projection, :bounds, :centre, :extents, :rotation
    
    def reproject_from(projection, point_or_points)
      projection.reproject_to(@projection, point_or_points)
    end
    
    def reproject_from_wgs84(point_or_points)
      reproject_from(Projection.wgs84, point_or_points)
    end
    
    def transform_bounds_to(target_projection)
      @projection.transform_bounds_to target_projection, bounds
    end
    
    def wgs84_bounds
      transform_bounds_to Projection.wgs84
    end
    
    def resolution_at(ppi)
      @scale * 0.0254 / ppi
    end
    
    def dimensions_at(ppi)
      @extents.map { |extent| (ppi * extent / @scale / 0.0254).floor }
    end
    
    def coord_corners(margin_in_mm = 0)
      metres = margin_in_mm * 0.001 * @scale
      @extents.map do |extent|
        [ -0.5 * extent - metres, 0.5 * extent + metres ]
      end.inject(&:product).values_at(0,2,3,1).map do |point|
        @centre.plus point.rotate_by_degrees(@rotation)
      end
    end
    
    def wgs84_corners
      @projection.reproject_to_wgs84 coord_corners
    end
    
    def coords_to_mm(coords)
      coords.one_or_many do |easting, northing|
        [ easting - bounds.first.first, bounds.last.last - northing ].map do |metres|
          1000.0 * metres / scale
        end
      end
    end
    
    def mm_corners(*args)
      coords_to_mm coord_corners(*args).reverse
    end
    
    def overlaps?(bounds)
      axes = [ [ 1, 0 ], [ 0, 1 ] ].map { |axis| axis.rotate_by_degrees(@rotation) }
      bounds.inject(&:product).map do |corner|
        axes.map { |axis| corner.minus(@centre).dot(axis) }
      end.transpose.zip(@extents).none? do |projections, extent|
        projections.max < -0.5 * extent || projections.min > 0.5 * extent
      end
    end
    
    def write_world_file(path, resolution)
      topleft = [ @centre, @extents.rotate_by_degrees(-@rotation), [ :-, :+ ] ].transpose.map { |coord, extent, plus_minus| coord.send(plus_minus, 0.5 * extent) }
      WorldFile.write topleft, resolution, @rotation, path
    end
    
    def write_oziexplorer_map(path, name, image, ppi)
      dimensions = dimensions_at(ppi)
      pixel_corners = dimensions.each.with_index.map { |dimension, order| [ 0, dimension ].rotate(order) }.inject(:product).values_at(0,2,3,1)
      calibration_strings = [ pixel_corners, wgs84_corners ].transpose.map.with_index do |(pixel_corner, wgs84_corner), index|
        dmh = [ wgs84_corner, [ [ ?E, ?W ], [ ?N, ?S ] ] ].transpose.reverse.map do |coord, hemispheres|
          [ coord.abs.floor, 60 * (coord.abs - coord.abs.floor), coord > 0 ? hemispheres.first : hemispheres.last ]
        end
        "Point%02i,xy,%i,%i,in,deg,%i,%f,%c,%i,%f,%c,grid,,,," % [ index+1, pixel_corner, dmh ].flatten
      end
      path.open("w") do |file|
        file << %Q[OziExplorer Map Data File Version 2.2
#{name}
#{image}
1 ,Map Code,
WGS 84,WGS84,0.0000,0.0000,WGS84
Reserved 1
Reserved 2
Magnetic Variation,,,E
Map Projection,Transverse Mercator,PolyCal,No,AutoCalOnly,Yes,BSBUseWPX,No
#{calibration_strings.join ?\n}
Projection Setup,0.000000000,#{projection.central_meridian},#{projection.scale_factor},500000.00,10000000.00,,,,,
Map Feature = MF ; Map Comment = MC     These follow if they exist
Track File = TF      These follow if they exist
Moving Map Parameters = MM?    These follow if they exist
MM0,Yes
MMPNUM,4
#{pixel_corners.reverse.map.with_index { |pixel_corner, index| "MMPXY,#{index+1},#{pixel_corner.join ?,}" }.join ?\n}
#{wgs84_corners.reverse.map.with_index { |wgs84_corner, index| "MMPLL,#{index+1},#{wgs84_corner.join ?,}" }.join ?\n}
MM1B,#{resolution_at ppi}
MOP,Map Open Position,0,0
IWH,Map Image Width/Height,#{dimensions.join ?,}
].gsub(/\r\n|\r|\n/, "\r\n")
      end
    end
    
    def declination
      @declination ||= begin
        today = Date.today
        easting, northing = @projection_centre
        query = { "lat1" => northing, "lon1" => easting, "model" => "WMM", "startYear" => today.year, "startMonth" => today.month, "startDay" => today.day, "resultFormat" => "xml" }
        uri = URI::HTTP.build :host => "www.ngdc.noaa.gov", :path => "/geomag-web/calculators/calculateDeclination"
        HTTP.post(uri, query.to_query) do |response|
          begin
            REXML::Document.new(response.body).elements["//declination"].text.to_f
          rescue REXML::ParseException
            raise ServerError.new("couldn't get magnetic declination value")
          end
        end
      end
    end
    
    def xml
      millimetres = @extents.map { |extent| 1000.0 * extent / @scale }
      REXML::Document.new.tap do |xml|
        xml << REXML::XMLDecl.new(1.0, "utf-8")
        attributes = {
          "version" => 1.1,
          "baseProfile" => "full",
          "xmlns" => "http://www.w3.org/2000/svg",
          "xmlns:xlink" => "http://www.w3.org/1999/xlink",
          "xmlns:ev" => "http://www.w3.org/2001/xml-events",
          "xmlns:sodipodi" => "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd",
          "xmlns:inkscape" => "http://www.inkscape.org/namespaces/inkscape",
          "xml:space" => "preserve",
          "width"  => "#{millimetres[0]}mm",
          "height" => "#{millimetres[1]}mm",
          "viewBox" => "0 0 #{millimetres[0]} #{millimetres[1]}",
        }
        xml.add_element("svg", attributes) do |svg|
          svg.add_element("sodipodi:namedview", "borderlayer" => true)
          svg.add_element("defs")
          svg.add_element("rect", "x" => 0, "y" => 0, "width" => millimetres[0], "height" => millimetres[1], "fill" => "white")
        end
      end
    end
  end
  
  InternetError = Class.new(Exception)
  ServerError = Class.new(Exception)
  BadGpxKmlFile = Class.new(Exception)
  BadLayerError = Class.new(Exception)
  NoVectorPDF = Class.new(Exception)
  
  module RetryOn
    def retry_on(*exceptions)
      intervals = [ 1, 2, 2, 4, 4, 8, 8 ]
      begin
        yield
      rescue *exceptions => e
        case
        when intervals.any?
          sleep(intervals.shift) and retry
        when File.identical?(__FILE__, $0)
          raise InternetError.new(e.message)
        else
          $stderr.puts "Error: #{e.message}"
          sleep(60) and retry
        end
      end
    end
  end
  
  module HTTP
    extend RetryOn
    def self.request(uri, req)
      retry_on(Timeout::Error, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EINVAL, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError, SocketError, ServerError) do
        use_ssl = uri.scheme == "https"
        response = Net::HTTP.start(uri.host, uri.port, :use_ssl => use_ssl, :read_timeout => 600) { |http| http.request(req) }
        case response
        when Net::HTTPSuccess then yield response
        else response.error!
        end
      end
    end

    def self.get(uri, *args, &block)
      request uri, Net::HTTP::Get.new(uri.request_uri, *args), &block
    end

    def self.post(uri, body, *args, &block)
      req = Net::HTTP::Post.new(uri.request_uri, *args)
      req.body = body.to_s
      request uri, req, &block
    end
    
    def self.head(uri, *args, &block)
      request uri, Net::HTTP::Head.new(uri.request_uri, *args), &block
    end
  end
  
  module ArcGIS
    def self.get_json(uri, *args)
      HTTP.get(uri, *args) do |response|
        JSON.parse(response.body).tap do |result|
          raise ServerError.new(result["error"]["message"]) if result["error"]
        end
      end
    rescue JSON::ParserError
      raise ServerError.new "unexpected response format"
    end
    
    def self.post_json(uri, body, *args)
      HTTP.post(uri, body, *args) do |response|
        JSON.parse(response.body).tap do |result|
          if result["error"]
            message = result["error"]["message"]
            details = result["error"]["details"]
            raise ServerError.new [ *message, *details ].join(?\n)
          end
        end
      end
    rescue JSON::ParserError
      raise ServerError.new "unexpected response format"
    end
  end
  
  module WFS
    def self.get_xml(uri, *args)
      HTTP.get(uri, *args) do |response|
        case response.content_type
        when "text/xml", "application/xml"
          REXML::Document.new(response.body).tap do |xml|
            raise ServerError.new xml.elements["//ows:ExceptionText/text()"] if xml.elements["ows:ExceptionReport"]
          end
        else raise ServerError.new "unexpected response format"
        end
      end
    end
  end
  
  class Source
    SVG_PRESENTATION_ATTRIBUTES = %w[alignment-baseline baseline-shift clip-path clip-rule clip color-interpolation-filters color-interpolation color-profile color-rendering color cursor direction display dominant-baseline fill-opacity fill-rule fill filter flood-color flood-opacity font-family font-size-adjust font-size font-stretch font-style font-variant font-weight glyph-orientation-horizontal glyph-orientation-vertical image-rendering kerning letter-spacing lighting-color marker-end marker-mid marker-start mask opacity overflow pointer-events shape-rendering stop-color stop-opacity stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit stroke-opacity stroke-width stroke text-anchor text-decoration text-rendering unicode-bidi visibility word-spacing writing-mode]
    
    def initialize(name, params)
      @name = name
      @params = params
    end
    attr_reader :name, :params, :path, :sublayers
    
    def exist?
      path.nil? || path.exist?
    end
    
    def predicate_for(category)
      case category
      when nil then "@class=''"
      when ""  then "@class"
      else "@class='#{category}' or starts-with(@class,'#{category} ') or contains(@class,' #{category} ') or ends-with(@class,' #{category}')"
      end
    end
    
    def rerender(xml, map)
      xml.elements.each("/svg/g[@id='#{name}' or starts-with(@id,'#{name}#{SEGMENT}')][*]") do |group|
        id = group.attributes["id"]
        sublayer = id.split(/^#{name}#{SEGMENT}?/).last
        puts "  #{sublayer}" unless id == name
        [ *params, *params[sublayer] ].inject({}) do |memo, (command, args)|
          memo.deep_merge case command
          when "symbol"    then { "symbols" => { "" => args } }
          when "pattern"   then { "patterns" => { "" => args } }
          when "dupe"      then { "dupes" => { "" => args } }
          when "sample"    then { "samples" => { "" => args } }
          when "endpoint"  then { "inpoints" => { "" => args }, "outpoints" => { "" => args } }
          when "endpoints" then { "inpoints" => args, "outpoints" => args }
          when "inpoint"   then { "inpoints" => { "" => args } }
          when "outpoint"  then { "outpoints" => { "" => args } }
          else { command => args }
          end
        end.inject([]) do |memo, (command, args)|
          case command
          when %r{^\./} then memo << [ command, args ]
          when "opacity" then memo << [ "self::/@style", "opacity:#{args}" ]
          when "dash"
            case args
            when nil             then memo << [ ".//[@stroke-dasharray]/@stroke-dasharray", nil ]
            when String, Numeric then memo << [ ".//path", { "stroke-dasharray" => args } ]
            end
          when "order"
            args.reverse.map do |category|
              "./g[#{predicate_for category}]"
            end.each do |xpath|
              group.elements.collect(xpath, &:remove).reverse.each do |element|
                group.unshift element
              end
            end
          when "symbols"
            args.each do |categories, elements|
              [ categories ].flatten.map do |category|
                [ "./g[#{predicate_for category}]/use[not(xlink:href)]", [ id, *category.split(?\s), "symbol" ].join(SEGMENT) ]
              end.select do |xpath, symbol_id|
                group.elements[xpath]
              end.each do |xpath, symbol_id|
                memo << [ "//svg/defs", { "g" => { "id" => symbol_id } } ]
                memo << [ "//svg/defs/g[@id='#{symbol_id}']", elements ]
                memo << [ xpath, { "xlink:href" => "##{symbol_id}"} ]
              end
            end
          when "patterns"
            args.each do |categories, elements|
              [ categories ].flatten.map do |category|
                [ "./g[#{predicate_for category}]", [ id, *category.split(?\s), "pattern" ].join(SEGMENT) ]
              end.select do |xpath, pattern_id|
                group.elements["#{xpath}//path[not(@fill='none')]"]
              end.each do |xpath, pattern_id|
                memo << [ "//svg/defs", { "pattern" => { "id" => pattern_id, "patternUnits" => "userSpaceOnUse", "patternTransform" => "rotate(#{-map.rotation})" } } ]
                memo << [ "//svg/defs/pattern[@id='#{pattern_id}']", elements ]
                memo << [ xpath, { "fill" => "url(##{pattern_id})"} ]
              end
            end
          when "dupes"
            args.each do |categories, names|
              [ categories ].flatten.each do |category|
                xpath = "./g[#{predicate_for category}]"
                group.elements.each(xpath) do |group|
                  classes = group.attributes["class"].to_s.split(?\s)
                  original_id = [ id, *classes, "original" ].join SEGMENT
                  elements = group.elements.map(&:remove)
                  [ *names ].each do |name|
                    group.add_element "use", "xlink:href" => "##{original_id}", "class" => [ name, *classes ].join(?\s)
                  end
                  original = group.add_element("g", "id" => original_id)
                  elements.each do |element|
                    original.elements << element
                  end
                end
              end
            end
          when "samples"
            args.each do |categories, attributes|
              [ categories ].flatten.map do |category|
                [ "./g[#{predicate_for category}]", category]
              end.select do |xpath, category|
                group.elements["#{xpath}//path"]
              end.each do |xpath, category|
                elements = case attributes
                when Array then attributes.map(&:to_a).inject(&:+) || []
                when Hash  then attributes.map(&:to_a)
                end.map { |key, value| { key => value } }
                interval = elements.find { |hash| hash["interval"] }.delete("interval")
                elements.reject!(&:empty?)
                symbol_ids = elements.map.with_index do |element, index|
                  [ id, *category.split(?\s), "symbol", *(index if elements.many?) ].join(SEGMENT).tap do |symbol_id|
                    memo << [ "//svg/defs", { "g" => { "id" => symbol_id } } ]
                    memo << [ "//svg/defs/g[@id='#{symbol_id}']", element ]
                  end
                end
                group.elements.each("#{xpath}//path") do |path|
                  uses = []
                  path.attributes["d"].to_s.split(/ Z| Z M | M |M /).reject(&:empty?).each do |subpath|
                    subpath.split(/ L | C -?[\d\.]+ -?[\d\.]+ -?[\d\.]+ -?[\d\.]+ /).map do |pair|
                      pair.split(?\s).map(&:to_f)
                    end.segments.inject(0.5) do |alpha, segment|
                      angle = 180.0 * segment.difference.angle / Math::PI
                      while alpha * interval < segment.distance
                        segment[0] = segment.along(alpha * interval / segment.distance)
                        translate = segment[0].round(MM_DECIMAL_DIGITS).join ?\s
                        uses << { "use" => {"transform" => "translate(#{translate}) rotate(#{angle.round 2})", "xlink:href" => "##{symbol_ids.sample}" } }
                        alpha = 1.0
                      end
                      alpha - segment.distance / interval
                    end
                  end
                  memo << [ xpath, uses ]
                end
              end
            end
          when "inpoints", "outpoints"
            index = %w[inpoints outpoints].index command
            args.each do |categories, attributes|
              [ categories ].flatten.map do |category|
                [ "./g[#{predicate_for category}]", [ id, *category.split(?\s), command ].join(SEGMENT) ]
              end.select do |xpath, symbol_id|
                group.elements["#{xpath}//path[@fill='none']"]
              end.each do |xpath, symbol_id|
                memo << [ "//svg/defs", { "g" => { "id" => symbol_id } } ]
                memo << [ "//svg/defs/g[@id='#{symbol_id}']", attributes ]
                group.elements.each("#{xpath}//path[@fill='none']") do |path|
                  uses = []
                  path.attributes["d"].to_s.split(/ Z| Z M | M |M /).reject(&:empty?).each do |subpath|
                    subpath.split(/ L | C -?[\d\.]+ -?[\d\.]+ -?[\d\.]+ -?[\d\.]+ /).values_at(0,1,-2,-1).map do |pair|
                      pair.split(?\s).map(&:to_f)
                    end.segments[-index].rotate(index).tap do |segment|
                      angle = 180.0 * segment.difference.angle / Math::PI
                      translate = segment[0].round(MM_DECIMAL_DIGITS).join ?\s
                      uses << { "use" => { "transform" => "translate(#{translate}) rotate(#{angle.round 2})", "xlink:href" => "##{symbol_id}" } }
                    end
                  end
                  memo << [ xpath, uses ]
                end
              end
            end
          when *SVG_PRESENTATION_ATTRIBUTES then memo << [ "self::", { command => args } ]
          when *sublayers
          else
            if args.is_a? Hash
              keys = args.keys & SVG_PRESENTATION_ATTRIBUTES
              values = args.values_at *keys
              svg_args = Hash[keys.zip values]
              [ *command ].each do |category|
                memo << [ "./g[#{predicate_for category}]", svg_args ]
                memo << [ "./g[@class]/use[#{predicate_for category}]", svg_args ]
              end if svg_args.any?
            end
          end
          memo
        end.each.with_index do |(xpath, args), index|
          case args
          when nil
            REXML.each(group, xpath, &:remove)
          when Hash, Array
            REXML::XPath.each(group, xpath) do |node|
              case node
              when REXML::Element
                case args
                when Array then args.map(&:to_a).inject(&:+) || []
                when Hash  then args
                end.each do |key, value|
                  case value
                  when Hash then node.add_element key, value
                  else node.add_attribute key, value
                  end
                end
              end
            end
          else
            REXML::XPath.each(group, xpath) do |node|
              case node
              when REXML::Attribute then node.element.attributes[node.name] = args
              when REXML::Element   then [ *args ].each { |tag| node.add_element tag }
              when REXML::Text      then node.value = args
              end
            end
          end
        end
        until group.elements.each(".//g[not(*)]", &:remove).empty? do
        end
      end
    end
  end
  
  module VectorRenderer
    def render_svg(map)
      unless map.rotation.zero?
        w, h = map.bounds.map { |bound| 1000.0 * (bound.max - bound.min) / map.scale }
        t = Math::tan(map.rotation * Math::PI / 180.0)
        d = (t * t - 1) * Math::sqrt(t * t + 1)
        if t >= 0
          y = (t * (h * t - w) / d).abs
          x = (t * y).abs
        else
          x = -(t * (h + w * t) / d).abs
          y = -(t * x).abs
        end
        transform = "translate(#{x} #{-y}) rotate(#{map.rotation})"
      end
      
      draw(map) do |sublayer|
        yield(sublayer).tap do |group|
          group.add_attributes("transform" => transform) if group && transform
        end
      end
    end
  end
  
  module RasterRenderer
    def initialize(*args)
      super(*args)
      ext = params["ext"] || "png"
      @path = Pathname.pwd + "#{name}.#{ext}"
    end
    
    def resolution_for(map)
      params["resolution"] || map.scale / 12500.0
    end
    
    def create(map)
      resolution = resolution_for map
      dimensions = map.extents.map { |extent| (extent / resolution).ceil }
      pixels = dimensions.inject(:*) > 500000 ? " (%.1fMpx)" % (0.000001 * dimensions.inject(:*)) : nil
      puts "Creating: %s, %ix%i%s @ %.1f m/px" % [ name, *dimensions, pixels, resolution]
      Dir.mktmppath do |temp_dir|
        FileUtils.cp get_raster(map, dimensions, resolution, temp_dir), path
      end
    end
    
    def render_svg(map)
      resolution = resolution_for map
      transform = "scale(#{1000.0 * resolution / map.scale})"
      opacity = params["opacity"] || 1
      dimensions = map.extents.map { |extent| (extent / resolution).ceil }
      
      href = if respond_to?(:embed_image) && params["embed"] != false
        Dir.mktmppath do |temp_dir|
          raster_path = embed_image(temp_dir)
          base64 = Base64.encode64 raster_path.read(:mode => "rb")
          mimetype = %x[identify -quiet -verbose "#{raster_path}"][/image\/\w+/] || "image/png"
          "data:#{mimetype};base64,#{base64}"
        end
      else
        raise BadLayerError.new("#{name} raster image not found at #{path}") unless path.exist?
        path.basename
      end
      
      layer = yield
      if layer
        if params["masks"]
          defs = layer.elements["//svg/defs"]
          filter_id, mask_id = "#{name}#{SEGMENT}filter", "#{name}#{SEGMENT}mask"
          defs.elements.each("[@id='#{filter_id}' or @id='#{mask_id}']", &:remove)
          defs.add_element("filter", "id" => filter_id) do |filter|
            filter.add_element "feColorMatrix", "type" => "matrix", "in" => "SourceGraphic", "values" => "0 0 0 0 1   0 0 0 0 1   0 0 0 0 1   0 0 0 -1 1"
          end
          defs.add_element("mask", "id" => mask_id) do |mask|
            mask.add_element("g", "filter" => "url(##{filter_id})") do |g|
              g.add_element "rect", "width" => "100%", "height" => "100%", "fill" => "none", "stroke" => "none"
              [ *params["masks"] ].each do |id|
                g.add_element "use", "xlink:href" => "##{id}"
              end
            end
          end
          layer.add_element("g", "mask" => "url(##{mask_id})")
        else
          layer
        end.add_element("image", "transform" => transform, "width" => dimensions[0], "height" => dimensions[1], "image-rendering" => "optimizeQuality", "xlink:href" => href)
      end
    end
  end
  
  class TiledServer < Source
    include RasterRenderer
    
    def get_raster(map, dimensions, resolution, temp_dir)
      src_path = temp_dir + "#{name}.txt"
      vrt_path = temp_dir + "#{name}.vrt"
      tif_path = temp_dir + "#{name}.tif"
      tfw_path = temp_dir + "#{name}.tfw"
      
      tiles(map, resolution, temp_dir).each do |tile_bounds, tile_resolution, tile_path|
        topleft = [ tile_bounds.first.min, tile_bounds.last.max ]
        WorldFile.write topleft, tile_resolution, 0, Pathname.new("#{tile_path}w")
      end.map(&:last).join(?\n).tap do |path_list|
        File.write src_path, path_list
        %x[gdalbuildvrt -input_file_list "#{src_path}" "#{vrt_path}"] unless path_list.empty?
      end

      density = 0.01 * map.scale / resolution
      %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:black -type TrueColor -depth 8 "#{tif_path}"]
      if vrt_path.exist?
        map.write_world_file tfw_path, resolution
        resample = params["resample"] || "cubic"
        projection = Projection.new(params["projection"])
        %x[gdalwarp -s_srs "#{projection}" -t_srs "#{map.projection}" -r #{resample} "#{vrt_path}" "#{tif_path}"]
      end
      
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert -quiet "#{tif_path}" "#{raster_path}"]
      end
    end
  end
  
  class TiledMapServer < TiledServer
    def tiles(map, raster_resolution, temp_dir)
      tile_sizes = params["tile_sizes"]
      tile_limit = params["tile_limit"]
      crops = params["crops"] || [ [ 0, 0 ], [ 0, 0 ] ]
      
      cropped_tile_sizes = [ tile_sizes, crops ].transpose.map { |tile_size, crop| tile_size - crop.inject(:+) }
      projection = Projection.new(params["projection"])
      bounds = map.transform_bounds_to(projection)
      extents = bounds.map { |bound| bound.max - bound.min }
      origins = bounds.transpose.first
      
      zoom, resolution, counts = (Math::log2(Math::PI * EARTH_RADIUS / raster_resolution) - 7).ceil.downto(1).map do |zoom|
        resolution = Math::PI * EARTH_RADIUS / 2 ** (zoom + 7)
        counts = [ extents, cropped_tile_sizes ].transpose.map { |extent, tile_size| (extent / resolution / tile_size).ceil }
        [ zoom, resolution, counts ]
      end.find do |zoom, resolution, counts|
        counts.inject(:*) < tile_limit
      end
      
      format, name = params.values_at("format", "name")
      
      counts.map { |count| (0...count).to_a }.inject(:product).map.with_index do |indices, count|
        tile_path = temp_dir + "tile.#{indices.join ?.}.png"
  
        cropped_centre = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
          origin + tile_size * (index + 0.5) * resolution
        end
        centre = [ cropped_centre, crops ].transpose.map { |coord, crop| coord - 0.5 * crop.inject(:-) * resolution }
        bounds = [ indices, cropped_tile_sizes, origins ].transpose.map do |index, tile_size, origin|
          [ origin + index * tile_size * resolution, origin + (index + 1) * tile_size * resolution ]
        end
  
        longitude, latitude = projection.reproject_to_wgs84(centre)
  
        attributes = [ "longitude", "latitude", "zoom", "format", "hsize", "vsize", "name" ]
        values     = [  longitude,   latitude,   zoom,   format,      *tile_sizes,   name  ]
        uri_string = [ attributes, values ].transpose.inject(params["uri"]) do |string, array|
          attribute, value = array
          string.gsub(Regexp.new("\\$\\{#{attribute}\\}"), value.to_s)
        end
        uri = URI.parse(uri_string)
  
        retries_on_blank = params["retries_on_blank"] || 0
        (1 + retries_on_blank).times do
          HTTP.get(uri) do |response|
            tile_path.open("wb") { |file| file << response.body }
            %x[mogrify -quiet -crop #{cropped_tile_sizes.join ?x}+#{crops.first.first}+#{crops.last.last} -type TrueColor -depth 8 -format png -define png:color-type=2 "#{tile_path}"]
          end
          non_blank_fraction = %x[convert "#{tile_path}" -fill white +opaque black -format "%[fx:mean]" info:].to_f
          break if non_blank_fraction > 0.995
        end
        
        $stdout << "\r  (#{count + 1} of #{counts.inject(&:*)} tiles)"
        [ bounds, resolution, tile_path ]
      end.tap { puts }
    end
  end
  
  class ArcGISRaster < Source
    include RasterRenderer
    UNDERSCORES = /[\s\(\)]/
    attr_reader :service, :headers
    
    def initialize(*args)
      super(*args)
      params["tile_sizes"] ||= [ 2048, 2048 ]
      params["url"] ||= (params["https"] ? URI::HTTPS : URI::HTTP).build(:host => params["host"]).to_s
      service_type = params["image"] ? "ImageServer" : "MapServer"
      params["url"] = [ params["url"], params["instance"] || "arcgis", "rest", "services", *params["folder"], params["service"], service_type ].join(?/)
    end
    
    def get_tile(bounds, sizes, options)
      srs = { "wkt" => options["wkt"] }.to_json
      query = {
        "bbox" => bounds.transpose.flatten.join(?,),
        "bboxSR" => srs,
        "imageSR" => srs,
        "size" => sizes.join(?,),
        "f" => "image"
      }
      if params["image"]
        query["format"] = "png24",
        query["interpolation"] = params["interpolation"] || "RSP_BilinearInterpolation"
      else
        %w[layers layerDefs dpi format dynamicLayers].each do |key|
          query[key] = options[key] if options[key]
        end
        query["transparent"] = true
      end
      
      url = params["url"]
      export = params["image"] ? "exportImage" : "export"
      uri = URI.parse "#{url}/#{export}?#{query.to_query}"
      
      HTTP.get(uri, headers) do |response|
        block_given? ? yield(response.body) : response.body
      end
    end
    
    def tiles(map, resolution, margin = 0)
      cropped_tile_sizes = params["tile_sizes"].map { |tile_size| tile_size - margin }
      dimensions = map.bounds.map { |bound| ((bound.max - bound.min) / resolution).ceil }
      origins = [ map.bounds.first.min, map.bounds.last.max ]
      
      cropped_size_lists = [ dimensions, cropped_tile_sizes ].transpose.map do |dimension, cropped_tile_size|
        [ cropped_tile_size ] * ((dimension - 1) / cropped_tile_size) << 1 + (dimension - 1) % cropped_tile_size
      end
      
      bound_lists = [ cropped_size_lists, origins, [ :+, :- ] ].transpose.map do |cropped_sizes, origin, increment|
        boundaries = cropped_sizes.inject([ 0 ]) { |memo, size| memo << size + memo.last }
        [ 0..-2, 1..-1 ].map.with_index do |range, index|
          boundaries[range].map { |offset| origin.send increment, (offset + index * margin) * resolution }
        end.transpose.map(&:sort)
      end
      
      size_lists = cropped_size_lists.map do |cropped_sizes|
        cropped_sizes.map { |size| size + margin }
      end
      
      offset_lists = cropped_size_lists.map do |cropped_sizes|
        cropped_sizes[0..-2].inject([0]) { |memo, size| memo << memo.last + size }
      end
      
      [ bound_lists, size_lists, offset_lists ].map do |axes|
        axes.inject(:product)
      end.transpose.select do |bounds, sizes, offsets|
        map.overlaps? bounds
      end
    end
    
    def get_service
      if params["cookie"]
        cookie = HTTP.head(URI.parse params["cookie"]) { |response| response["Set-Cookie"] }
        @headers = { "Cookie" => cookie }
      end
      uri = URI.parse params["url"] + "?f=json"
      @service = ArcGIS.get_json uri, headers
      service["layers"].each { |layer| layer["name"] = layer["name"].gsub(UNDERSCORES, ?_) } if service["layers"]
      service["mapName"] = service["mapName"].gsub(UNDERSCORES, ?_) if service["mapName"]
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      get_service
      scale = params["scale"] || map.scale
      options = { "dpi" => scale * 0.0254 / resolution, "wkt" => map.projection.wkt_esri, "format" => "png32" }
      
      tile_set = tiles(map, resolution)
      dataset = tile_set.map.with_index do |(tile_bounds, tile_sizes, tile_offsets), index|
        $stdout << "\r  (#{index} of #{tile_set.length} tiles)"
        tile_path = temp_dir + "tile.#{index}.png"
        tile_path.open("wb") do |file|
          file << get_tile(tile_bounds, tile_sizes, options)
        end
        [ tile_bounds, tile_sizes, tile_offsets, tile_path ]
      end
      puts
      
      temp_dir.join(path.basename).tap do |raster_path|
        density = 0.01 * map.scale / resolution
        alpha = params["background"] ? %Q[-background "#{params['background']}" -alpha Remove] : nil
        if map.rotation.zero?
          sequence = dataset.map do |_, tile_sizes, tile_offsets, tile_path|
            %Q[#{OP} "#{tile_path}" +repage -repage +#{tile_offsets[0]}+#{tile_offsets[1]} #{CP}]
          end.join ?\s
          resize = (params["resolution"] || params["scale"]) ? "-resize #{dimensions.join ?x}!" : "" # TODO: check?
          %x[convert #{sequence} -compose Copy -layers mosaic -units PixelsPerCentimeter -density #{density} #{resize} #{alpha} "#{raster_path}"]
        else
          src_path = temp_dir + "#{name}.txt"
          vrt_path = temp_dir + "#{name}.vrt"
          tif_path = temp_dir + "#{name}.tif"
          tfw_path = temp_dir + "#{name}.tfw"
          dataset.each do |tile_bounds, _, _, tile_path|
            topleft = [ tile_bounds.first.first, tile_bounds.last.last ]
            WorldFile.write topleft, resolution, 0, Pathname.new("#{tile_path}w")
          end.map(&:last).join(?\n).tap do |path_list|
            File.write src_path, path_list
          end
          %x[gdalbuildvrt -input_file_list "#{src_path}" "#{vrt_path}"]
          %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type TrueColorMatte -depth 8 "#{tif_path}"]
          map.write_world_file tfw_path, resolution
          %x[gdalwarp -s_srs "#{map.projection}" -t_srs "#{map.projection}" -dstalpha -r cubic "#{vrt_path}" "#{tif_path}"]
          %x[convert "#{tif_path}" -quiet #{alpha} "#{raster_path}"]
        end
      end
    end
  end
  
  class FeatureSource < Source
    include VectorRenderer
    
    def initialize(*args)
      super(*args)
      @path = Pathname.pwd + "#{name}.json"
      @sublayers = params["features"].keys
    end
    
    def shapefile_features(map, source, options)
      Enumerator.new do |yielder|
        shape_path = Pathname.new source["path"]
        projection = Projection.new %x[gdalsrsinfo -o proj4 "#{shape_path}"].gsub(/['"]+/, "").strip
        xmin, xmax, ymin, ymax = map.transform_bounds_to(projection).map(&:sort).flatten
        layer = options["name"]
        sql   = %Q[-sql "%s"] % options["sql"] if options["sql"]
        where = %Q[-where "%s"] % [ *options["where"] ].map { |clause| "(#{clause})" }.join(" AND ") if options["where"]
        srs   = %Q[-t_srs "#{map.projection}"]
        spat  = %Q[-spat #{xmin} #{ymin} #{xmax} #{ymax}]
        Dir.mktmppath do |temp_dir|
          json_path = temp_dir + "data.json"
          %x[ogr2ogr #{sql || where} #{srs} #{spat} -f GeoJSON "#{json_path}" "#{shape_path}" #{layer unless sql}]
          JSON.parse(json_path.read).fetch("features").each do |feature|
            geometry = feature["geometry"]
            dimension = case geometry["type"]
            when "Polygon", "MultiPolygon" then 2
            when "LineString" then 1
            when "Point", "MultiPoint" then 0
            else raise BadLayerError.new("cannot process features of type #{geometry['type']}")
            end
            data = case geometry["type"]
            when "Polygon"      then geometry["coordinates"]
            when "MultiPolygon" then geometry["coordinates"].flatten(1)
            when "LineString"   then [ geometry["coordinates"] ]
            when "Point"        then [ geometry["coordinates"] ]
            when "MultiPoint"   then geometry["coordinates"]
            else abort("geometry type #{geometry['type']} unimplemented")
            end
            attributes = feature["properties"]
            yielder << [ dimension, data, attributes ]
          end
        end
      end
    end
    
    def arcgis_features(map, source, options)
      options["definition"] ||= "1 = 1" if options.delete "redefine"
      url = if URI.parse(source["url"]).path.split(?/).any?
        source["url"]
      else
        [ source["url"], source["instance"] || "arcgis", "rest", "services", *source["folder"], source["service"], source["type"] || "MapServer" ].join(?/)
      end
      uri = URI.parse "#{url}?f=json"
      service = ArcGIS.get_json uri, source["headers"]
      ring = (map.coord_corners << map.coord_corners.first).reverse
      if params["local-reprojection"] || source["local-reprojection"] || options["local-reprojection"]
        wkt  = service["spatialReference"]["wkt"]
        wkid = service["spatialReference"]["latestWkid"] || service["spatialReference"]["wkid"]
        projection = Projection.new wkt ? "ESRI::#{wkt}".gsub(?", '\"') : "epsg:#{wkid == 102100 ? 3857 : wkid}"
        geometry = { "rings" => [ map.projection.reproject_to(projection, ring) ] }.to_json
      else
        sr = { "wkt" => map.projection.wkt_esri }.to_json
        geometry = { "rings" => [ ring ] }.to_json
      end
      geometry_query = { "geometry" => geometry, "geometryType" => "esriGeometryPolygon" }
      options["id"] ||= service["layers"].find do |layer|
        layer["name"] == options["name"]
      end.fetch("id")
      layer_id = options["id"]
      uri = URI.parse "#{url}/#{layer_id}?f=json"
      max_record_count, fields, types, type_id_field, min_scale, max_scale = ArcGIS.get_json(uri, source["headers"]).values_at *%w[maxRecordCount fields types typeIdField minScale maxScale]
      fields = fields.map { |field| { field["name"] => field } }.inject({}, &:merge)
      oid_field_name = fields.values.find { |field| field["type"] == "esriFieldTypeOID" }.fetch("name", nil)
      oid_field_alias = fields.values.find { |field| field["type"] == "esriFieldTypeOID" }.fetch("alias", oid_field_name)
      names = fields.map { |name, field| { field["alias"] => name } }.inject({}, &:merge)
      types = types && types.map { |type| { type["id"] => type } }.inject(&:merge)
      type_field_name = type_id_field && fields.values.find { |field| field["alias"] == type_id_field }.fetch("name")
      pages = Enumerator.new do |yielder|
        if options["definition"] && !service["supportsDynamicLayers"]
          uri = URI.parse "#{url}/identify"
          index_attribute = options["page-by"] || source["page-by"] || oid_field_alias || "OBJECTID"
          scale = options["scale"]
          scale ||= max_scale.zero? ? min_scale.zero? ? map.scale : 2 * min_scale : (min_scale + max_scale) / 2
          pixels = map.wgs84_bounds.map do |bound|
            bound.reverse.inject(&:-) * 96.0 * 110000 / scale / 0.0254
          end.map(&:ceil)
          bounds = projection ? map.transform_bounds_to(projection) : map.bounds
          query = {
            "f" => "json",
            "layers" => "all:#{layer_id}",
            "tolerance" => 0,
            "mapExtent" => bounds.transpose.flatten.join(?,),
            "imageDisplay" => [ *pixels, 96 ].join(?,),
            "returnGeometry" => true,
          }
          query["sr"] = sr if sr
          query.merge! geometry_query
          paginate = nil
          indices = []
          loop do
            definitions = [ *options["definition"], *paginate ]
            definition = "(#{definitions.join ') AND ('})"
            paged_query = query.merge("layerDefs" => "#{layer_id}:1 = 0) OR (#{definition}")
            page = ArcGIS.post_json(uri, paged_query.to_query, source["headers"]).fetch("results", [])
            break unless page.any?
            yielder << page
            indices += page.map { |feature| feature["attributes"][index_attribute] }
            # paginate = "#{index_attribute} NOT IN (#{indices.join ?,})"
            paginate = "#{index_attribute} > #{indices.map(&:to_i).max}"
          end
        elsif options["page-by"] || source["page-by"]
          uri = URI.parse "#{url}/#{layer_id}/query"
          index_attribute = options["page-by"] || source["page-by"]
          per_page = [ *max_record_count, *options["per-page"], *source["per-page"], 500 ].min
          field_names = [ index_attribute, *type_field_name, *options["category"], *options["rotate"], *options["label"] ] & fields.keys
          paginate = nil
          indices = []
          loop do
            query = geometry_query.merge("f" => "json", "returnGeometry" => true, "outFields" => field_names.join(?,))
            query["inSR"] = query["outSR"] = sr if sr
            clauses = [ *options["where"], *paginate ]
            query["where"] = "(#{clauses.join ') AND ('})" if clauses.any?
            page = ArcGIS.post_json(uri, query.to_query, source["headers"]).fetch("features", [])
            break unless page.any?
            yielder << page
            indices += page.map { |feature| feature["attributes"][index_attribute] }
            # paginate = "#{index_attribute} NOT IN (#{indices.join ?,})"
            paginate = "#{index_attribute} > #{indices.map(&:to_i).max}"
          end
        else
          where = [ *options["where"] ].map { |clause| "(#{clause})" }.join(" AND ") if options["where"]
          per_page = [ *max_record_count, *options["per-page"], *source["per-page"], 500 ].min
          if options["definition"]
            definitions = [ *options["definition"] ]
            definition = "(#{definitions.join ') AND ('})"
            layer = { "source" => { "type" => "mapLayer", "mapLayerId" => layer_id }, "definitionExpression" => "1 = 0) OR (#{definition}" }.to_json
            resource = "dynamicLayer"
            base_query = { "f" => "json", "layer" => layer }
          else
            resource = layer_id
            base_query = { "f" => "json" }
          end
          uri = URI.parse "#{url}/#{resource}/query"
          query = base_query.merge(geometry_query).merge("returnIdsOnly" => true)
          query["inSR"] = sr if sr
          query["where"] = where if where
          field_names = [ *oid_field_name, *type_field_name, *options["category"], *options["rotate"], *options["label"] ] & fields.keys
          ArcGIS.post_json(uri, query.to_query, source["headers"]).fetch("objectIds").to_a.each_slice(per_page) do |object_ids|
            query = base_query.merge("objectIds" => object_ids.join(?,), "returnGeometry" => true, "outFields" => field_names.join(?,))
            query["outSR"] = sr if sr
            page = ArcGIS.post_json(uri, query.to_query, source["headers"]).fetch("features", [])
            yielder << page
          end
        end
      end
      Enumerator.new do |yielder|
        pages.each do |page|
          page.each do |feature|
            geometry = feature["geometry"]
            raise BadLayerError.new("feature contains no geometry") unless geometry
            dimension, key = [ 0, 0, 1, 2 ].zip(%w[x points paths rings]).find { |dimension, key| geometry.key? key }
            data = case key
            when "x"
              point = geometry.values_at("x", "y")
              [ projection ? map.reproject_from(projection, point) : point ]
            when "points"
              points = geometry[key]
              projection ? map.reproject_from(projection, points) : points
            when "paths", "rings"
              geometry[key].map do |points|
                projection ? map.reproject_from(projection, points) : points
              end
            end
            names_values = feature["attributes"].map do |name_or_alias, value|
              value = nil if %w[null Null NULL <null> <Null> <NULL>].include? value
              [ names.fetch(name_or_alias, name_or_alias), value ]
            end
            attributes = Hash[names_values]
            type = types && types[attributes[type_field_name]]
            attributes.each do |name, value|
              case
              when type_field_name == name # name is the type field name
                attributes[name] = type["name"] if type
              when values = type && type["domains"][name] && type["domains"][name]["codedValues"] # name is the subtype field name
                coded_value = values.find { |coded_value| coded_value["code"] == value }
                attributes[name] = coded_value["name"] if coded_value
              when values = fields[name] && fields[name]["domain"] && fields[name]["domain"]["codedValues"] # name is a coded value field name
                coded_value = values.find { |coded_value| coded_value["code"] == value }
                attributes[name] = coded_value["name"] if coded_value
              end
            end
            yielder << [ dimension, data, attributes ]
          end
        end
      end
    end
    
    def wfs_features(map, source, options)
      url = source["url"]
      type_name = options["name"]
      per_page = [ *options["per-page"], *source["per-page"], 500 ].min
      headers = source["headers"]
      base_query = { "service" => "wfs", "version" => "2.0.0" }
      
      query = base_query.merge("request" => "DescribeFeatureType", "typeName" => type_name).to_query
      xml = WFS.get_xml URI.parse("#{url}?#{query}"), headers
      namespace, type = xml.elements["xsd:schema/xsd:element[@name='#{type_name}']/@type"].value.split ?:
      names = xml.elements.each("xsd:schema/[@name='#{type}']//xsd:element[@name][starts-with(@type,'xsd:')]/@name").map(&:value)
      types = xml.elements.each("xsd:schema/[@name='#{type}']//xsd:element[@name][starts-with(@type,'xsd:')]/@type").map(&:value)
      methods = names.zip(types).map do |name, type|
        method = case type
        when *%w[xsd:float xsd:double xsd:decimal] then :to_f
        when *%w[xsd:int xsd:short]                then :to_i
        else                                            :to_s
        end
        { name => method }
      end.inject({}, &:merge)
      
      geometry_name = xml.elements["xsd:schema/[@name='#{type}']//xsd:element[@name][starts-with(@type,'gml:')]/@name"].value
      geometry_type = xml.elements["xsd:schema/[@name='#{type}']//xsd:element[@name][starts-with(@type,'gml:')]/@type"].value
      dimension = case geometry_type
      when *%w[gml:PointPropertyType gml:MultiPointPropertyType] then 0
      when *%w[gml:CurvePropertyType gml:MultiCurvePropertyType] then 1
      when *%w[gml:SurfacePropertyType gml:MultiSurfacePropertyType] then 2
      else raise BadLayerError.new "unsupported geometry type '#{geometry_type}'"
      end
      
      query = base_query.merge("request" => "GetCapabilities").to_query
      xml = WFS.get_xml URI.parse("#{url}?#{query}"), headers
      default_crs = xml.elements["wfs:WFS_Capabilities/FeatureTypeList/FeatureType[Name[text()='#{namespace}:#{type_name}']]/DefaultCRS"].text
      wkid = default_crs.match(/EPSG::(\d+)$/)[1]
      projection = Projection.new "epsg:#{wkid}"
      
      points = map.projection.reproject_to(projection, map.coord_corners)
      polygon = [ *points, points.first ].map { |corner| corner.reverse.join ?\s }.join ?,
      bounds_filter = "INTERSECTS(#{geometry_name},POLYGON((#{polygon})))"
      
      filters = [ bounds_filter, *options["filter"], *options["where"] ]
      names &= [ *options["category"], *options["rotate"], *options["label"] ]
      get_query = {
        "request" => "GetFeature",
        "typeNames" => type_name,
        "propertyName" => names.join(?,),
        "count" => per_page,
        "cql_filter" => "(#{filters.join ') AND ('})"
      }
      
      Enumerator.new do |yielder|
        index = 0
        loop do
          query = base_query.merge(get_query).merge("startIndex" => index).to_query
          xml = WFS.get_xml URI.parse("#{url}?#{query}"), headers
          xml.elements.each("wfs:FeatureCollection/wfs:member/#{namespace}:#{type_name}") do |member|
            elements = names.map do |name|
              member.elements["#{namespace}:#{name}"]
            end
            values = methods.values_at(*names).zip(elements).map do |method, element|
              element ? element.attributes["xsi:nil"] == "true" ? nil : element.text ? element.text.send(method) : "" : nil
            end
            attributes = Hash[names.zip values]
            data = case dimension
            when 0
              member.elements.each(".//gml:pos/text()").map(&:to_s).map do |string|
                string.split.map(&:to_f).reverse
              end
            when 1, 2
              member.elements.each(".//gml:posList/text()").map(&:to_s).map do |string|
                string.split.map(&:to_f).each_slice(2).map(&:reverse)
              end
            end.map do |point_or_points|
              map.reproject_from projection, point_or_points
            end
            yielder << [ dimension, data, attributes ]
          end.length == per_page || break
          index += per_page
        end
      end
    end
    
    def create(map)
      puts "Downloading: #{name}"
      feature_hull = map.coord_corners(1.0)
      
      %w[host instance folder service cookie].map do |key|
        { key => params.delete(key) }
      end.inject(&:merge).tap do |default|
        params["sources"] = { "default" => default }
      end unless params["sources"]
      
      sources = params["sources"].map do |name, source|
        source["headers"] ||= {}
        if source["cookie"]
          cookies = HTTP.head(URI.parse source["cookie"]) do |response|
            response.get_fields('Set-Cookie').map { |string| string.split(?;).first }
          end
          source["headers"]["Cookie"] = cookies.join("; ") if cookies.any?
        end
        source["url"] ||= (source["https"] ? URI::HTTPS : URI::HTTP).build(:host => source["host"]).to_s
        source["headers"]["Referer"] ||= source["url"]
        source["headers"]["User-Agent"] ||= "Ruby/#{RUBY_VERSION}"
        { name => source }
      end.inject(&:merge)
      
      params["features"].inject([]) do |memo, (key, value)|
        case value
        when Array then memo + value.map { |val| [ key, val ] }
        else memo << [ key, value ]
        end
      end.map do |key, value|
        case value
        when Fixnum then [ key, { "id" => value } ]    # key is a sublayer name, value is a service layer name
        when String then [ key, { "name" => value } ]  # key is a sublayer name, value is a service layer ID
        when Hash   then [ key, value ]                # key is a sublayer name, value is layer options
        when nil
          case key
          when String then [ key, { "name" => key } ]  # key is a service layer name
          when Hash                                    # key is a service layer name with definition
            [ key.first.first, { "name" => key.first.first, "definition" => key.first.last } ]
          when Fixnum                                  # key is a service layer ID
            [ sources.values.first["service"]["layers"].find { |layer| layer["id"] == key }.fetch("name"), { "id" => key } ]
          end
        end
      end.reject do |sublayer, options|
        params["exclude"].include? sublayer
      end.group_by(&:first).map do |sublayer, options_group|
        [ sublayer, options_group.map(&:last) ]
      end.map do |sublayer, options_array|
        $stdout << "  #{sublayer}"
        features = []
        options_array.inject([]) do |memo, options|
          memo << [] unless memo.any? && options.delete("fallback")
          memo.last << (memo.last.last || {}).merge(options)
          memo
        end.each do |fallbacks|
          fallbacks.inject(nil) do |error, options|
            substitutions = [ *options.delete("category") ].map do |category_or_hash, hash|
              case category_or_hash
              when Hash then category_or_hash
              else { category_or_hash => hash || {} }
              end
            end.inject({}, &:merge)
            options["category"] = substitutions.keys
            source = sources[options["source"] || sources.keys.first]
            begin
              case source["protocol"]
              when "arcgis"     then    arcgis_features(map, source, options)
              when "wfs"        then       wfs_features(map, source, options)
              when "shapefile"  then shapefile_features(map, source, options)
              end
            rescue InternetError, ServerError => error
              next error
            end.each do |dimension, data, attributes|
              case dimension
              when 0 then data.clip_points! feature_hull
              when 1 then data.clip_lines!  feature_hull
              when 2 then data.clip_polys!  feature_hull
              end
              next if data.empty?
              categories = substitutions.map do |name, substitutes|
                value = attributes.fetch(name, name)
                substitutes.fetch(value, value).to_s.to_category
              end
              case attributes[options["rotate"]]
              when nil, 0, "0"
                categories << "no-angle"
              else
                categories << "angle"
                angle = case options["rotation-style"]
                when "arithmetic" then      attributes[options["rotate"]].to_f
                when "geographic" then 90 - attributes[options["rotate"]].to_f
                else                   90 - attributes[options["rotate"]].to_f
                end
              end if options["rotate"]
              features << { "dimension" => dimension, "data" => data, "categories" => categories }.tap do |feature|
                feature["label-only"] = options["label-only"] if options["label-only"]
                feature["angle"] = angle if angle
                [ *options["label"] ].map do |key|
                  attributes.fetch(key, key)
                end.tap do |labels|
                  feature["labels"] = labels unless labels.map(&:to_s).all?(&:empty?)
                end
              end
              $stdout << "\r  #{sublayer} (#{features.length} feature#{?s unless features.one?})"
            end
            break nil
          end.tap do |error|
            raise error if error
          end
        end
        puts
        { sublayer => features }
      end.inject(&:merge).tap do |layers|
        Dir.mktmppath do |temp_dir|
          json_path = temp_dir + "#{name}.json"
          json_path.open("w") { |file| file << layers.to_json }
          FileUtils.cp json_path, path
        end
      end
    end
    
    def draw(map)
      raise BadLayerError.new("source file not found at #{path}") unless path.exist?
      JSON.parse(path.read).reject do |sublayer, features|
        params["exclude"].include? sublayer
      end.map do |sublayer, features|
        [ sublayer, features.reject { |feature| feature["label-only"] } ]
      end.reject do |sublayer, features|
        features.empty?
      end.map do |sublayer, features|
        [ yield(sublayer), sublayer, features ]
      end.select(&:first).each do |group, sublayer, features|
        puts "  #{sublayer}"
        id = group.attributes["id"]
        features.group_by do |feature|
          feature["categories"].reject(&:empty?).join(?\s)
        end.each do |categories, features|
          category_group = group.add_element("g", "class" => categories)
          category_group.add_attribute "id", [ id, *categories.split(?\s) ].join(SEGMENT) unless categories.empty?
          features.each do |feature|
            case feature["dimension"]
            when 0
              angle = feature["angle"]
              map.coords_to_mm(feature["data"]).round(MM_DECIMAL_DIGITS).each do |x, y|
                transform = "translate(#{x} #{y}) rotate(#{(angle || 0) - map.rotation})"
                category_group.add_element "use", "transform" => transform
              end
            when 1, 2
              close, fill_options = case feature["dimension"]
              when 1 then [ nil, { "fill" => "none" }         ]
              when 2 then [ ?Z,  { "fill-rule" => "nonzero" } ]
              end
              feature["data"].reject(&:empty?).map do |coords|
                map.coords_to_mm coords
              end.map do |points|
                case k = params[sublayer] && params[sublayer]["bezier"]
                when Numeric then points.to_bezier(k, MM_DECIMAL_DIGITS, *close)
                when true    then points.to_bezier(1, MM_DECIMAL_DIGITS, *close)
                else              points.to_path_data(MM_DECIMAL_DIGITS, *close)
                end
              end.tap do |subpaths|
                category_group.add_element "path", fill_options.merge("d" => subpaths.join(?\s)) if subpaths.any?
              end
            end
          end
        end
      end
    end
    
    def labels(map)
      raise BadLayerError.new("source file not found at #{path}") unless path.exist?
      JSON.parse(path.read).reject do |sublayer, features|
        params["exclude"].include? sublayer
      end.inject([]) do |memo, (sublayer, features)|
        memo + features.select do |feature|
          feature.key?("labels")
        end.map(&:dup).each do |feature|
          feature["categories"].unshift sublayer
        end
      end
    end
  end
  
  class ArcGISVector < FeatureSource
    def initialize(*args)
      super(*args)
      params["sources"].each { |name, source| source["protocol"] = "arcgis" }
    end
  end
  
  class ReliefSource < Source
    include RasterRenderer
    
    def initialize(name, params)
      super(name, params.merge("ext" => "tif"))
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      src_path = temp_dir + "dem.txt"
      vrt_path = temp_dir + "dem.vrt"
      dem_path = temp_dir + "dem.tif"
      
      bounds = map.bounds.map do |lower, upper|
        [ lower - 10.0 * resolution, upper + 10.0 * resolution ]
      end
      
      if params["path"]
        [ *params["path"] ].map do |path|
          Pathname.glob path
        end.inject([], &:+).map(&:expand_path).tap do |paths|
          raise BadLayerError.new("no dem data files at specified path") if paths.empty?
        end
      else
        base_uri = URI.parse "http://www.ga.gov.au/gisimg/rest/services/topography/dem_s_1s/ImageServer/"
        wgs84_bounds = map.projection.transform_bounds_to Projection.wgs84, bounds
        base_query = { "f" => "json", "geometry" => wgs84_bounds.map(&:sort).transpose.flatten.join(?,) }
        query = base_query.merge("returnIdsOnly" => true, "where" => "category = 1").to_query
        raster_ids = ArcGIS.get_json(base_uri + "query?#{query}").fetch("objectIds")
        query = base_query.merge("rasterIDs" => raster_ids.join(?,), "format" => "TIFF").to_query
        tile_paths = ArcGIS.get_json(base_uri + "download?#{query}").fetch("rasterFiles").map do |file|
          file["id"][/[^@]*/]
        end.select do |url|
          url[/\.tif$/]
        end.map do |url|
          [ URI.parse(URI.escape url), temp_dir + url[/[^\/]*$/] ]
        end.each do |uri, tile_path|
          HTTP.get(uri) do |response|
            tile_path.open("wb") { |file| file << response.body }
          end
        end.map(&:last)
      end.join(?\n).tap do |path_list|
        File.write src_path, path_list
      end
      %x[gdalbuildvrt -input_file_list "#{src_path}" "#{vrt_path}"]
      
      dem_bounds = map.projection.transform_bounds_to Projection.new(vrt_path), bounds
      ulx, lrx, lry, uly = dem_bounds.flatten
      %x[gdal_translate -q -projwin #{ulx} #{uly} #{lrx} #{lry} "#{vrt_path}" "#{dem_path}"]
      
      scale = bounds.zip(dem_bounds).last.map do |bound|
        bound.inject(&:-)
      end.inject(&:/)
      
      temp_dir.join(path.basename).tap do |tif_path|
        relief_path = temp_dir + "#{name}-uncropped.tif"
        tfw_path = temp_dir + "#{name}.tfw"
        map.write_world_file tfw_path, resolution
        density = 0.01 * map.scale / resolution
        altitude, azimuth, exaggeration = params.values_at("altitude", "azimuth", "exaggeration")
        %x[gdaldem hillshade -compute_edges -s #{scale} -alt #{altitude} -z #{exaggeration} -az #{azimuth} "#{dem_path}" "#{relief_path}" -q]
        raise BadLayerError.new("invalid elevation data") unless $?.success?
        %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:none -type GrayscaleMatte -depth 8 "#{tif_path}"]
        %x[gdalwarp -t_srs "#{map.projection}" -r bilinear -srcnodata 0 -dstalpha "#{relief_path}" "#{tif_path}"]
        filters = []
        (params["median"].to_f / resolution).round.tap do |pixels|
          filters << "-statistic median #{2 * pixels + 1}" if pixels > 0
        end
        params["bilateral"].to_f.round.tap do |threshold|
          sigma = (500.0 / resolution).round
          filters << "-selective-blur 0x#{sigma}+#{threshold}%" if threshold > 0
        end
        %x[mogrify -channel RGBA -quiet -virtual-pixel edge #{filters.join ?\s} "#{tif_path}"] if filters.any?
      end
    end
    
    def embed_image(temp_dir)
      raise BadLayerError.new("hillshade image not found at #{path}") unless path.exist?
      highlights = params["highlights"]
      shade = %Q["#{path}" -colorspace Gray -fill white -opaque none -level 0,65% -negate -alpha Copy -fill black +opaque black]
      sun = %Q["#{path}" -colorspace Gray -fill black -opaque none -level 80%,100% +level 0,#{highlights}% -alpha Copy -fill yellow +opaque yellow]
      temp_dir.join("overlay.png").tap do |overlay_path|
        %x[convert -quiet #{OP} #{shade} #{CP} #{OP} #{sun} #{CP} -composite -define png:color-type=6 "#{overlay_path}"]
      end
    end
  end
  
  class VegetationSource < Source
    include RasterRenderer
    
    def get_raster(map, dimensions, resolution, temp_dir)
      src_path = temp_dir + "#{name}.txt"
      vrt_path = temp_dir + "#{name}.vrt"
      tif_path = temp_dir + "#{name}.tif"
      tfw_path = temp_dir + "#{name}.tfw"
      clut_path = temp_dir + "#{name}-clut.png"
      mask_path = temp_dir + "#{name}-mask.png"
      
      [ *params["path"] ].map do |path|
        Pathname.glob path
      end.inject([], &:+).map(&:expand_path).tap do |paths|
        raise BadLayerError.new("no vegetation data file specified") if paths.empty?
      end.join(?\n).tap do |path_list|
        File.write src_path, path_list
      end
      %x[gdalbuildvrt -input_file_list "#{src_path}" "#{vrt_path}"]
      
      map.write_world_file tfw_path, resolution
      %x[convert -size #{dimensions.join ?x} canvas:white -type Grayscale -depth 8 "#{tif_path}"]
      %x[gdalwarp -t_srs "#{map.projection}" "#{vrt_path}" "#{tif_path}"]
      
      low, high, factor = { "low" => 0, "high" => 100, "factor" => 0.0 }.merge(params["contrast"] || {}).values_at("low", "high", "factor")
      %x[convert -size 1x256 canvas:black "#{clut_path}"]
      params["mapping"].map do |key, value|
        "j==#{key} ? %.5f : u" % (value < low ? 0.0 : value > high ? 1.0 : (value - low).to_f / (high - low))
      end.each do |fx|
        %x[mogrify -fx "#{fx}" "#{clut_path}"]
      end
      %x[mogrify -sigmoidal-contrast #{factor}x50% "#{clut_path}"]
      %x[convert "#{tif_path}" "#{clut_path}" -clut "#{mask_path}"]
      
      woody, nonwoody = params["colour"].values_at("woody", "non-woody")
      density = 0.01 * map.scale / resolution
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert -size #{dimensions.join ?x} -units PixelsPerCentimeter -density #{density} canvas:"#{nonwoody}" #{OP} "#{mask_path}" -background "#{woody}" -alpha Shape #{CP} -composite "#{raster_path}"]
      end
    end
    
    def embed_image(temp_dir)
      raise BadLayerError.new("vegetation raster image not found at #{path}") unless path.exist?
      path
    end
  end
  
  module NoCreate
    def create(map)
      raise BadLayerError.new("#{name} file not found at #{path}")
    end
  end
  
  class CanvasSource < Source
    include RasterRenderer
    include NoCreate
    
    def resolution_for(map)
      return params["resolution"] if params["resolution"]
      raise BadLayerError.new("canvas image not found at #{path}") unless path.exist?
      pixels_per_centimeter = %x[convert "#{path}" -units PixelsPerCentimeter -format "%[resolution.x]" info:]
      raise BadLayerError.new("bad canvas image at #{path}") unless $?.success?
      map.scale * 0.01 / pixels_per_centimeter.to_f
    end
  end
  
  class ImportSource < Source
    include RasterRenderer
    
    def resolution_for(map)
      import_path = Pathname.new(params["path"]).expand_path
      Math::sqrt(0.5) * [ [ 0, 0 ], [ 1, 1 ] ].map do |point|
        %x[echo #{point.join ?\s} | gdaltransform "#{import_path}" -t_srs "#{map.projection}"].tap do |output|
          raise BadLayerError.new("couldn't use georeferenced file at #{import_path}") unless $?.success?
        end.split(?\s)[0..1].map(&:to_f)
      end.distance
    end
    
    def get_raster(map, dimensions, resolution, temp_dir)
      import_path = Pathname.new(params["path"]).expand_path
      source_path = temp_dir + "source.tif"
      tfw_path = temp_dir + "#{name}.tfw"
      tif_path = temp_dir + "#{name}.tif"
      
      density = 0.01 * map.scale / resolution
      map.write_world_file tfw_path, resolution
      %x[convert -size #{dimensions.join ?x} canvas:none -type TrueColorMatte -depth 8 -units PixelsPerCentimeter -density #{density} "#{tif_path}"]
      %x[gdal_translate -expand rgba #{import_path} #{source_path}]
      %x[gdal_translate #{import_path} #{source_path}] unless $?.success?
      raise BadLayerError.new("couldn't use georeferenced file at #{import_path}") unless $?.success?
      %x[gdalwarp -t_srs "#{map.projection}" -r bilinear #{source_path} #{tif_path}]
      temp_dir.join(path.basename).tap do |raster_path|
        %x[convert "#{tif_path}" -quiet "#{raster_path}"]
      end
    end
  end
  
  class DeclinationSource < Source
    include VectorRenderer
    include NoCreate
    
    def draw(map)
      arrows = params["arrows"]
      bl, br, tr, tl = map.coord_corners
      width, height = map.extents
      margin = height * Math::tan((map.rotation + map.declination) * Math::PI / 180.0)
      spacing = params["spacing"] / Math::cos((map.rotation + map.declination) * Math::PI / 180.0)
      group = yield
      [ [ bl, br ], [ tl, tr ] ].map.with_index do |edge, index|
        [ [ 0, 0 - margin ].min, [ width, width - margin ].max ].map do |extension|
          edge.along (extension + margin * index) / width
        end
      end.map do |edge|
        (edge.distance / spacing).ceil.times.map do |n|
          edge.along(n * spacing / edge.distance)
        end
      end.transpose.map do |line|
        map.coords_to_mm line
      end.map.with_index do |points, index|
        step = arrows || points.distance
        start = index.even? ? 0.25 : 0.75
        (points.distance / step - start).ceil.times.map do |n|
          points.along (start + n) * step / points.distance
        end.unshift(points.first).push(points.last)
      end.tap do |lines|
        lines.clip_lines! map.mm_corners
      end.map do |points|
        points.to_path_data MM_DECIMAL_DIGITS
      end.each do |d|
        group.add_element("path", "d" => d, "fill" => "none", "marker-mid" => arrows ? "url(##{name}#{SEGMENT}marker)" : "none")
      end.tap do
        group.elements["//svg/defs"].add_element("marker", "id" => "#{name}#{SEGMENT}marker", "markerWidth" => 20, "markerHeight" => 8, "viewBox" => "-20 -4 20 8", "orient" => "auto") do |marker|
          marker.add_element("path", "d" => "M 0 0 L -20 -4 L -13 0 L -20 4 Z", "stroke" => "none", "fill" => params["stroke"] || "black")
        end if arrows
      end if group
    rescue ServerError => e
      raise BadLayerError.new(e.message)
    end
  end

  class GridSource < Source
    include VectorRenderer
    include NoCreate
    
    def initialize(*args)
      super(*args)
      params["labels"]["orientation"] = "uphill"
      params["labels"]["margin"] ||= 0.8
    end
    
    def grids(map)
      interval = params["interval"]
      Projection.utm_zone(map.bounds.inject(&:product), map.projection).inject do |range, zone|
        [ *range, zone ].min .. [ *range, zone ].max
      end.map do |zone|
        utm = Projection.utm(zone)
        eastings, northings = map.transform_bounds_to(utm).map do |bound|
          (bound[0] / interval).floor .. (bound[1] / interval).ceil
        end.map do |counts|
          counts.map { |count| count * interval }
        end
        grid = eastings.map do |easting|
          [ easting ].product northings.reverse
        end
        [ zone, utm, grid ]
      end
    end
    
    def draw(map)
      group = yield
      grids(map).map do |zone, utm, grid|
        wgs84_grid = grid.map do |lines|
          utm.reproject_to_wgs84 lines
        end
        eastings, northings = [ wgs84_grid, wgs84_grid.transpose ].map do |lines|
          lines.clip_lines Projection.utm_hull(zone)
        end
        [ eastings, northings, [ northings.map(&:first) ] ].map do |lines|
          lines.map do |line|
            map.coords_to_mm map.reproject_from_wgs84(line)
          end.clip_lines(map.mm_corners)
        end
      end.transpose.map do |lines|
        lines.inject([], &:+)
      end.zip(%w[eastings northings boundary]).each do |lines, category|
        group.add_element("g", "class" => category) do |group|
          lines.each do |line|
            group.add_element "path", "d" => line.to_path_data(MM_DECIMAL_DIGITS)
          end
        end if lines.any?
      end if group
    end
    
    def labels(map)
      params["label-spacing"] ? periodic_labels(map) : edge_labels(map)
    end
    
    def labels_percents(coord, interval)
      result = [ [ "%d" % (coord / 100000), 80 ], [ "%02d" % ((coord / 1000) % 100), 100 ] ]
      result << [ "%03d" % (coord % 1000), 80 ] unless interval % 1000 == 0
      result
    end
    
    def edge_labels(map)
      interval = params["interval"]
      corners = map.coord_corners(-5.0)
      grids(map).map do |zone, utm, grid|
        corners.zip(corners.perps).map.with_index do |(corner, perp), index|
          eastings, outgoing = index % 2 == 0, index < 2
          (eastings ? grid : grid.transpose).map do |line|
            coord = line[0][eastings ? 0 : 1]
            segment = map.reproject_from(utm, line).segments.find do |points|
              points.one? { |point| point.minus(corner).dot(perp) < 0.0 }
            end
            segment[outgoing ? 1 : 0] = segment.along(corner.minus(segment[0]).dot(perp) / segment.difference.dot(perp)) if segment
            [ coord, segment ]
          end.select(&:last).select do |coord, segment|
            corners.surrounds?(segment).any? && Projection.in_zone?(zone, segment[outgoing ? 1 : 0], map.projection)
          end.map do |coord, segment|
            labels, percents = labels_percents(coord, interval).transpose
            label_length = labels.zip(percents).map { |label, percent| label.length * percent / 100.0 }.inject(&:+) * 2.0
            segment_length = 1000.0 * segment.distance / map.scale
            fraction = label_length / segment_length
            fractions = outgoing ? [ 1.0 - fraction, 1.0 ] : [ 0.0, fraction ]
            baseline = fractions.map { |fraction| segment.along fraction }
            { "dimension" => 1, "data" => [ baseline ], "labels" => labels, "percents" => percents, "categories" => eastings ? "eastings" : "northings" }
          end
        end
      end.flatten
    end
    
    def periodic_labels(map)
      label_interval = params["label-spacing"] * params["interval"]
      grids(map).map do |zone, utm, grid|
        [ grid, grid.transpose ].map.with_index do |lines, index|
          lines.select(&:any?).map do |line|
            [ line, line[0][index] ]
          end.select do |line, coord|
            coord % label_interval == 0
          end.map do |line, coord|
            labels, percents = labels_percents(coord, label_interval).transpose
            line.segments.select do |segment|
              segment[0][1-index] % label_interval == 0
            end.select do |segment|
              Projection.in_zone?(zone, segment, utm).all?
            end.map do |segment|
              { "dimension" => 1, "data" => [ map.reproject_from(utm, segment) ], "labels" => labels, "percents" => percents, "categories" => index.zero? ? "eastings" : "northings" }
            end
          end
        end
      end.flatten
    end
  end
  
  class ControlSource < Source
    include VectorRenderer
    include NoCreate
    
    def initialize(*args)
      super(*args)
      @path = Pathname.new(params["path"]).expand_path
      params["labels"]["margin"] ||= params["diameter"] * 0.707
    end
    
    def types_waypoints
      gps_waypoints = GPS.new(path).waypoints
      [ [ /\d{2,3}/, :controls  ],
        [ /HH/,      :hashhouse ],
        [ /ANC/,     :anc       ],
        [ /W/,       :water     ],
      ].map do |selector, type|
        waypoints = gps_waypoints.map do |waypoint, name|
          [ waypoint, name[selector] ]
        end.select(&:last)
        [ type, waypoints ]
      end
    rescue BadGpxKmlFile => e
      raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
    end
    
    def draw(map)
      radius = 0.5 * params["diameter"]
      spot_diameter = params["spot-diameter"]
      
      group = yield
      types_waypoints.each do |type, waypoints|
        group.add_element("g", "class" => type) do |group|
          waypoints.map do |waypoint, label|
            point = map.coords_to_mm(map.reproject_from_wgs84(waypoint)).round(MM_DECIMAL_DIGITS)
            transform = "translate(#{point.join ?\s}) rotate(#{-map.rotation})"
            case type
            when :controls
              group.add_element("circle", "r" => radius, "fill" => "none", "transform" => transform)
              group.add_element("circle", "r" => 0.5 * spot_diameter, "stroke" => "none", "transform" => transform) if spot_diameter
            when :hashhouse, :anc
              angles = type == :hashhouse ? [ -90, -210, -330 ] : [ -45, -135, -225, -315 ]
              d = angles.map do |angle|
                [ radius, 0 ].rotate_by_degrees(angle)
              end.to_path_data(MM_DECIMAL_DIGITS, ?Z)
              group.add_element("path", "d" => d, "fill" => "none", "transform" => transform)
            when :water
              [
                "m -0.79942321,0.07985921 -0.005008,0.40814711 0.41816285,0.0425684 0,-0.47826034 -0.41315487,0.02754198 z",
                "m -0.011951449,-0.53885114 0,0.14266384",
                "m 0.140317871,-0.53885114 0,0.14266384",
                "m -0.38626833,0.05057523 c 0.0255592,0.0016777 0.0370663,0.03000538 0.0613473,0.03881043 0.0234708,0.0066828 0.0475564,0.0043899 0.0713631,0.0025165 0.007966,-0.0041942 0.0530064,-0.03778425 0.055517,-0.04287323 0.0201495,-0.01674888 0.0473913,-0.05858754 0.0471458,-0.08232678 l 0.005008,-0.13145777 c 2.5649e-4,-0.006711 -0.0273066,-0.0279334 -0.0316924,-0.0330336 -0.005336,-0.006207 0.006996,-0.0660504 -0.003274,-0.0648984 -0.0115953,-0.004474 -0.0173766,5.5923e-4 -0.0345371,-0.007633 -0.004228,-0.0128063 -0.006344,-0.0668473 0.0101634,-0.0637967 0.0278325,0.001678 0.0452741,0.005061 0.0769157,-0.005732 0.0191776,0 0.08511053,-0.0609335 0.10414487,-0.0609335 l 0.16846578,8.3884e-4 c 0.0107679,0 0.0313968,0.0284032 0.036582,0.03359 0.0248412,0.0302766 0.0580055,0.0372558 0.10330712,0.0520893 0.011588,0.001398 0.0517858,-0.005676 0.0553021,0.002517 0.007968,0.0265354 0.005263,0.0533755 0.003112,0.0635227 -0.002884,0.0136172 -0.0298924,-1.9573e-4 -0.0313257,0.01742 -0.001163,0.0143162 -4.0824e-4,0.0399429 -0.004348,0.0576452 -0.0239272,0.024634 -0.0529159,0.0401526 -0.0429639,0.0501152 l -6.5709e-4,0.11251671 c 0.003074,0.02561265 0.0110277,0.05423115 0.0203355,0.07069203 0.026126,0.0576033 0.0800901,0.05895384 0.0862871,0.06055043 0.002843,8.3885e-4 0.24674425,0.0322815 0.38435932,0.16401046 0.0117097,0.0112125 0.0374559,0.0329274 0.0663551,0.12144199 0.0279253,0.0855312 0.046922,0.36424768 0.0375597,0.36808399 -0.0796748,0.0326533 -0.1879149,0.0666908 -0.31675221,0.0250534 -0.0160744,-0.005201 0.001703,-0.11017354 -0.008764,-0.16025522 -0.0107333,-0.0513567 3.4113e-4,-0.15113981 -0.11080061,-0.17089454 -0.0463118,-0.008221 -0.19606469,0.0178953 -0.30110236,0.0400631 -0.05001528,0.0105694 -0.117695,0.0171403 -0.15336817,0.0100102 -0.02204477,-0.004418 -0.15733412,-0.0337774 -0.18225582,-0.0400072 -0.0165302,-0.004138 -0.053376,-0.006263 -0.10905742,0.0111007 -0.0413296,0.0128902 -0.0635168,0.0443831 -0.0622649,0.0334027 9.1434e-4,-0.008025 0.001563,-0.46374837 -1.0743e-4,-0.47210603 z",
                "m 0.06341799,-0.8057541 c -0.02536687,-2.7961e-4 -0.06606003,0.0363946 -0.11502538,0.0716008 -0.06460411,0.0400268 -0.1414687,0.0117718 -0.20710221,-0.009675 -0.0622892,-0.0247179 -0.16166212,-0.004194 -0.17010213,0.0737175 0.001686,0.0453982 0.0182594,0.1160762 0.0734356,0.11898139 0.0927171,-0.0125547 0.18821206,-0.05389 0.28159685,-0.0236553 0.03728388,0.0164693 0.0439921,0.0419813 0.04709758,0.0413773 l 0.18295326,0 c 0.003105,5.5923e-4 0.009814,-0.0249136 0.0470976,-0.0413773 0.0933848,-0.0302347 0.18887978,0.0111007 0.2815969,0.0236553 0.0551762,-0.002908 0.0718213,-0.0735832 0.0735061,-0.11898139 -0.00844,-0.0779145 -0.10788342,-0.0984409 -0.17017266,-0.0737175 -0.0656335,0.0214464 -0.14249809,0.0497014 -0.20710215,0.009675 -0.0498479,-0.0358409 -0.09110973,-0.0731946 -0.11636702,-0.0715309 -4.5577e-4,-3.076e-5 -9.451e-4,-6.432e-5 -0.001412,-6.991e-5 z",
                "m -0.20848487,-0.33159571 c 0.29568578,0.0460357 0.5475498,0.0168328 0.5475498,0.0168328",
                "m -0.21556716,-0.26911875 c 0.29568578,0.0460329 0.55463209,0.0221175 0.55463209,0.0221175",
              ].each do |d|
                d.gsub!(/\d+\.\d+/) { |number| number.to_f * radius * 0.8 }
                group.add_element("path", "fill" => "none", "d" => d, "transform" => transform)
              end
            end
          end
        end
      end if group
    end
    
    def labels(map)
      types_waypoints.reject do |type, waypoints|
        type == :water
      end.map do |type, waypoints|
        waypoints.map do |waypoint, label|
          { "dimension" => 0, "data" => [ map.reproject_from_wgs84(waypoint) ], "labels" => label, "categories" => type }
        end
      end.flatten(1)
    end
  end
  
  class OverlaySource < Source
    include VectorRenderer
    include NoCreate
    
    def initialize(*args)
      super(*args)
      @path = Pathname.new(params["path"]).expand_path
    end
    
    def draw(map)
      gps = GPS.new(path)
      group = yield
      return unless group
      [ [ :tracks, { "fill" => "none" }, nil ],
        [ :areas, { "fill-rule" => "nonzero" }, ?Z ]
      ].each do |feature, attributes, close|
        gps.send(feature).each do |list, name|
          points = map.coords_to_mm map.reproject_from_wgs84(list)
          d = points.to_path_data MM_DECIMAL_DIGITS, *close
          group.add_element "g", "class" => name.to_category do |group|
            group.add_element "path", attributes.merge("d" => d)
          end
        end
      end
      gps.waypoints.group_by do |coords, name|
        name.to_category
      end.each do |category, coords_names|
        coords = map.reproject_from_wgs84(coords_names.transpose.first)
        group.add_element("g", "class" => category) do |category_group|
          map.coords_to_mm(coords).round(MM_DECIMAL_DIGITS).each do |x, y|
            transform = "translate(#{x} #{y}) rotate(#{-map.rotation})"
            category_group.add_element "use", "transform" => transform
          end
        end
      end
    rescue BadGpxKmlFile => e
      raise BadLayerError.new("#{e.message} not a valid GPX or KML file")
    end
  end
  
  class LabelSource < Source
    include VectorRenderer
    LABELLING_ATTRIBUTES = %w[font-size letter-spacing word-spacing margin orientation position repeat deviation format collate]
    LABELLING_TRANSFORMS = %w[reduce buffer densify smooth minimum-area minimum-length remove]
    FONT_ASPECT_RATIO = 0.7
    
    def initialize(*args)
      super(*args)
      @features = [];
    end
    
    def add(source, map)
      sublayer = source.name
      source_params = params[sublayer] || {}
      source.labels(map).each do |feature|
        categories = [ *feature["categories"] ].map(&:to_s).reject(&:empty?).join(?\s)
        dimension = feature["dimension"]
        attributes = { "categories" => categories }
        attributes["percents"] = feature["percents"] if feature["percents"]
        transforms = { }
        source_params.select do |key, value|
          value.is_a?(Hash)
        end.select do |key, value|
          [ *key ].any? { |substring| categories.start_with? substring }
        end.values.inject(source_params, &:merge).tap do |merged_params|
          merged_params.each do |key, value|
            case key
            when *LABELLING_ATTRIBUTES then attributes[key] = value
            when *LABELLING_TRANSFORMS then transforms[key] = value
            end
          end
        end
        text = attributes["format"] ? attributes["format"] % feature["labels"] : [ *feature["labels"] ].map(&:to_s).reject(&:empty?).join(?\s)
        _, _, components = @features.find do |other_text, other_sublayer, _|
          other_sublayer == sublayer && other_text == text
        end if attributes["collate"]
        unless components
          components = [ ]
          @features << [ text, sublayer, components ]
        end
        data = case dimension
        when 0
          map.coords_to_mm feature["data"]
        when 1, 2
          feature["data"].map do |coords|
            map.coords_to_mm coords
          end
        end
        transforms.each do |transform, (arg, *args)|
          case transform
          when "reduce"
            case arg
            when "centreline"
              dimension = 1
              data.replace data.centreline(*args)
            when "centrepoints"
              dimension = 0
              data.replace data.centrepoints(*args)
            end if dimension == 2
          when "buffer"
            case dimension
            when 1 then data.replace data.buffer_lines(arg)
            when 2 then data.replace data.buffer_polygon(arg)
            end
          when "smooth"
            data.map! do |points|
              points.smooth(arg, 20)
            end if dimension == 1
          when "minimum-area"
            data.reject! do |points|
              points.signed_area.abs < arg
            end if dimension == 2
          when "densify"
            data.map! do |points|
              points.densify(arg, dimension == 2)
            end if dimension > 0
          when "remove"
            [ *arg ].each do |value|
              data.replace [] if case value
              when true    then true
              when String  then text == value
              when Regexp  then text =~ value
              when Numeric then text == value.to_s
              end
            end
          when "minimum-length"
            data.reject! do |points|
              points.segments.map(&:distance).inject(0.0, &:+) < arg
            end if dimension == 1
          end
        end
        data.each do |point_or_points|
          components << [ dimension, point_or_points, attributes ]
        end
      end if source.respond_to? :labels
    end
    
    def draw(map, &block)
      labelling_hull = map.mm_corners(-2)
      hulls, sublayers, dimensions, attributes, component_indices, categories, elements = @features.map do |text, sublayer, components|
        components.map.with_index do |component, component_index|
          dimension, data, attributes = component
          font_size      = attributes["font-size"]      || 1.5
          letter_spacing = attributes["letter-spacing"] || 0
          word_spacing   = attributes["word-spacing"]   || 0
          categories     = attributes["categories"]
          case dimension
          when 0
            margin = attributes["margin"] || 0
            lines = text.in_two
            width = lines.map(&:length).max * (font_size * FONT_ASPECT_RATIO + letter_spacing)
            height = lines.length * font_size
            transform = "translate(#{data.join ?\s}) rotate(#{-map.rotation})"
            [ *attributes["position"] ].map do |position|
              dx = position =~ /right$/ ? 1 : position =~ /left$/  ? -1 : 0
              dy = position =~ /^below/ ? 1 : position =~ /^above/ ? -1 : 0
              f = dx * dy == 0 ? 1 : 0.707
              text_anchor = dx > 0 ? "start" : dx < 0 ? "end" : "middle"
              text_elements = lines.map.with_index do |line, count|
                x = dx * f * margin
                y = ((lines.one? ? (1 + dy) * 0.5 : count + dy) - 0.15) * font_size + dy * f * margin
                REXML::Element.new("text").tap do |text|
                  text.add_attributes "text-anchor" => text_anchor, "transform" => transform, "x" => x, "y" => y
                  text.add_text line
                end
              end
              hull = [ [ dx, width ], [dy, height ] ].map do |d, l|
                [ d * f * margin + (d - 1) * 0.5 * l, d * f * margin + (d + 1) * 0.5 * l ]
              end.inject(&:product).values_at(0,2,3,1).map do |corner|
                corner.rotate_by_degrees(-map.rotation).plus(data)
              end
              [ hull, sublayer, dimension, attributes, component_index, categories, nil, text_elements ]
            end
          when 1, 2
            orientation = attributes["orientation"]
            deviation = attributes["deviation"] || 5
            text_length = attributes["percents"] ? 0 : text.length * (font_size * FONT_ASPECT_RATIO + letter_spacing) + text.count(?\s) * word_spacing
            distances = data.ring.map(&:distance)
            Enumerator.new do |yielder|
              indices, distance = [ 0, 1 ], distances[0]
              loop do
                while distance < text_length
                  index = indices.last
                  break if dimension == 2 && index == indices[0]
                  break if dimension == 1 && index == distances.length - 1
                  distance += distances[index]
                  index += 1
                  index %= distances.length
                  indices << index
                end
                break if distance < text_length
                while distance >= text_length
                  yielder << indices.dup unless distance >= text_length + distances[indices.first]
                  break if dimension == 2 && indices[1] == 0
                  distance -= distances[indices.shift]
                end
                break if distance >= text_length
              end
            end.map do |indices|
              [ data.values_at(*indices), distances.values_at(*indices).inject(&:+) ]
            end.reject do |baseline, length|
              baseline.cosines.any? { |cosine| cosine < 0.9 }
            end.map do |baseline, length|
              eigenvalue, eigenvector = baseline.principal_components.first
              sinuosity = length / baseline.values_at(0, -1).difference.norm
              [ baseline, eigenvalue, sinuosity ]
            end.reject do |baseline, eigenvalue, sinuosity|
              eigenvalue > deviation**2 || sinuosity > 1.25
            end.sort_by(&:last).map(&:first).map do |baseline|
              rightwards = baseline.values_at(0, -1).difference.rotate_by_degrees(map.rotation).first > 0
              hull = [ baseline ].buffer_lines(0.5 * font_size).flatten(1).convex_hull
              d = case orientation
              when "uphill"   then baseline
              when "downhill" then baseline.reverse
              else rightwards ? baseline : baseline.reverse
              end.to_path_data(MM_DECIMAL_DIGITS)
              id = [ name, sublayer, "path", d.hash ].join SEGMENT
              path_element = REXML::Element.new("path")
              path_element.add_attributes "id" => id, "d" => d
              text_element = REXML::Element.new("text")
              text_element.add_attributes "text-anchor" => "middle"
              text_element.add_element("textPath", "xlink:href" => "##{id}", "startOffset" => "50%", "alignment-baseline" => "middle") do |text_path|
                if attributes["percents"]
                  attributes["percents"].zip(text.split ?\s).each.with_index do |(percent, text_part), index|
                    text_path.add_text ?\s unless index.zero?
                    text_path.add_element("tspan", "font-size" => "#{percent}%") { |tspan| tspan.add_text text_part }
                  end
                else
                  text_path.add_text text
                end
              end
              [ hull, sublayer, dimension, attributes, component_index, categories, [ text_element, path_element ] ]
            end
          end.select do |hull, *args|
            labelling_hull.surrounds?(hull).all?
          end
        end.flatten(1).transpose
      end.reject(&:empty?).transpose
      return unless hulls
      
      conflicts = {}
      hulls.each.with_index do |hulls, feature_index|
        conflicts[feature_index] = {}
        hulls.each.with_index do |hull, candidate_index|
          conflicts[feature_index][candidate_index] = {}
        end
      end
      
      labels = hulls.map.with_index do |hulls, feature_index|
        hulls.map.with_index { |hull, candidate_index| [ feature_index, candidate_index ] }
      end.flatten(1)
      
      hulls.flatten(1).overlaps.each do |index1, index2|
        feature1_index, candidate1_index = label1 = labels[index1]
        feature2_index, candidate2_index = label2 = labels[index2]
        conflicts[feature1_index][candidate1_index][label2] = true
        conflicts[feature2_index][candidate2_index][label1] = true
      end
      
      dimensions.zip(component_indices).each.with_index do |(dimensions, component_indices), feature_index|
        dimensions.zip(component_indices).each.with_index do |(dimension, component1_index), candidate1_index|
          label1 = [ feature_index, candidate1_index ]
          component_indices.each.with_index.select do |component2_index, candidate2_index|
            candidate2_index < candidate1_index && component1_index == component2_index
          end.each do |component2_index, candidate2_index|
            label2 = [ feature_index, candidate2_index ]
            case dimension
            when 0
              conflicts[feature_index][candidate1_index][label2] = true
              conflicts[feature_index][candidate2_index][label1] = true
            end
          end
        end
      end
      
      hulls.zip(attributes).each.with_index do |(hulls, attributes), feature_index|
        buffer = attributes.map { |attributes| attributes["repeat"] }.compact.max
        hulls.overlaps(buffer).each do |candidate1_index, candidate2_index|
          label1 = [ feature_index, candidate1_index ]
          label2 = [ feature_index, candidate2_index ]
          conflicts[feature_index][candidate1_index][label2] = true
          conflicts[feature_index][candidate2_index][label1] = true
        end if buffer
      end
      
      labels = [ ]
      pending = conflicts.map do |feature_index, candidate_indices|
        { feature_index => candidate_indices.map do |candidate_index, label_conflicts|
          { candidate_index => label_conflicts.dup }
        end.inject(&:merge) }
      end.inject(&:merge) || { }
      
      while pending.any?
        pending.map do |feature_index, candidate_indices|
          candidate_indices.map do |candidate_index, label_conflicts|
            [ [ feature_index, candidate_index ], label_conflicts, [ label_conflicts.length, pending[feature_index].length ] ]
          end
        end.flatten(1).min_by(&:last).tap do |label, label_conflicts, _|
          [ label, *label_conflicts.keys ].each do |feature_index, candidate_index|
            pending[feature_index].delete(candidate_index) if pending[feature_index]
          end
          labels << label
        end
        pending.reject! do |feature_index, candidate_indices|
          candidate_indices.empty?
        end
      end
      
      (conflicts.keys - labels.map(&:first)).each do |feature_index|
        conflicts[feature_index].min_by do |candidate_index, conflicts|
          [ (conflicts.keys & labels).count, candidate_index ]
        end.tap do |candidate_index, conflicts|
          labels.reject! do |label|
            conflicts[label] && labels.map(&:first).count(label[0]) > 1
          end
          labels << [ feature_index, candidate_index ]
        end
      end
      
      5.times do
        labels.select do |feature_index, candidate_index|
          dimensions[feature_index][candidate_index] == 0
        end.each do |label|
          feature_index, current_candidate_index = label
          counts_candidates = conflicts[feature_index].select do |new_candidate_index, conflicts|
            component_indices[feature_index][new_candidate_index] == component_indices[feature_index][current_candidate_index]
          end.map do |new_candidate_index, conflicts|
            [ (labels & conflicts.keys - [ label ]).count, new_candidate_index ]
          end
          label[1] = counts_candidates.min.last
        end
      end
      
      sublayer_names = sublayers.flatten.uniq
      layers = Hash[sublayer_names.zip sublayer_names.map(&block)]
      defs = layers.values.first.elements["//svg/defs"] if labels.any?
      labels.map do |feature_index, candidate_index|
        sublayer = sublayers[feature_index][candidate_index]
        category = categories[feature_index][candidate_index]
        element = elements[feature_index][candidate_index]
        group = layers[sublayer].elements["./g[@class='#{category}')]"] || layers[sublayer].add_element("g", "class" => category)
        [ element ].flatten.each do |element|
          case element.name
          when "text", "textPath" then group.elements << element
          when "path" then defs.elements << element
          end
        end
      end
    end
  end
  
  module KMZ
    TILE_SIZE = 512
    TILT = 40 * Math::PI / 180.0
    FOV = 30 * Math::PI / 180.0
    
    def self.style
      lambda do |style|
        style.add_element("ListStyle", "id" => "hideChildren") do |list_style|
          list_style.add_element("listItemType") { |type| type.text = "checkHideChildren" }
        end
      end
    end
    
    def self.lat_lon_box(bounds)
      lambda do |box|
        [ %w[west east south north], bounds.flatten ].transpose.each do |limit, value|
          box.add_element(limit) { |lim| lim.text = value }
        end
      end
    end
    
    def self.region(bounds, topmost = false)
      lambda do |region|
        region.add_element("Lod") do |lod|
          lod.add_element("minLodPixels") { |min| min.text = topmost ? 0 : TILE_SIZE / 2 }
          lod.add_element("maxLodPixels") { |max| max.text = -1 }
        end
        region.add_element("LatLonAltBox", &lat_lon_box(bounds))
      end
    end
    
    def self.network_link(bounds, path)
      lambda do |network|
        network.add_element("Region", &region(bounds))
        network.add_element("Link") do |link|
          link.add_element("href") { |href| href.text = path }
          link.add_element("viewRefreshMode") { |mode| mode.text = "onRegion" }
          link.add_element("viewFormat")
        end
      end
    end
    
    def self.build(map, ppi, image_path, kmz_path)
      wgs84_bounds = map.wgs84_bounds
      degrees_per_pixel = 180.0 * map.resolution_at(ppi) / Math::PI / EARTH_RADIUS
      dimensions = wgs84_bounds.map { |bound| bound.reverse.inject(:-) / degrees_per_pixel }
      max_zoom = Math::log2(dimensions.max).ceil - Math::log2(TILE_SIZE).to_i
      topleft = [ wgs84_bounds.first.min, wgs84_bounds.last.max ]
      
      Dir.mktmppath do |temp_dir|
        file_name = image_path.basename
        source_path = temp_dir + file_name
        worldfile_path = temp_dir + "#{file_name}w"
        FileUtils.cp image_path, source_path
        map.write_world_file worldfile_path, map.resolution_at(ppi)
        
        pyramid = (0..max_zoom).map do |zoom|
          resolution = degrees_per_pixel * 2**(max_zoom - zoom)
          degrees_per_tile = resolution * TILE_SIZE
          counts = wgs84_bounds.map { |bound| (bound.reverse.inject(:-) / degrees_per_tile).ceil }
          dimensions = counts.map { |count| count * TILE_SIZE }
          
          tfw_path = temp_dir + "zoom-#{zoom}.tfw"
          tif_path = temp_dir + "zoom-#{zoom}.tif"
          %x[convert -size #{dimensions.join ?x} canvas:none -type TrueColorMatte -depth 8 "#{tif_path}"]
          WorldFile.write topleft, resolution, 0, tfw_path
          
          %x[gdalwarp -s_srs "#{map.projection}" -t_srs "#{Projection.wgs84}" -r bilinear -dstalpha "#{source_path}" "#{tif_path}"]
          
          indices_bounds = [ topleft, counts, [ :+, :- ] ].transpose.map do |coord, count, increment|
            boundaries = (0..count).map { |index| coord.send increment, index * degrees_per_tile }
            [ boundaries[0..-2], boundaries[1..-1] ].transpose.map(&:sort)
          end.map do |tile_bounds|
            tile_bounds.each.with_index.to_a
          end.inject(:product).map(&:transpose).map do |tile_bounds, indices|
            { indices => tile_bounds }
          end.inject({}, &:merge)
          $stdout << "\r  resizing image pyramid (#{100 * (2**(zoom + 1) - 1) / (2**(max_zoom + 1) - 1)}%)"
          { zoom => indices_bounds }
        end.inject({}, &:merge)
        puts
        
        kmz_dir = temp_dir + map.name
        kmz_dir.mkdir
        
        pyramid.map do |zoom, indices_bounds|
          zoom_dir = kmz_dir + zoom.to_s
          zoom_dir.mkdir
          
          tif_path = temp_dir + "zoom-#{zoom}.tif"
          indices_bounds.map do |indices, tile_bounds|
            index_dir = zoom_dir + indices.first.to_s
            index_dir.mkdir unless index_dir.exist?
            tile_kml_path = index_dir + "#{indices.last}.kml"
            tile_png_name = "#{indices.last}.png"
            
            xml = REXML::Document.new
            xml << REXML::XMLDecl.new(1.0, "UTF-8")
            xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1") do |kml|
              kml.add_element("Document") do |document|
                document.add_element("Style", &style)
                document.add_element("Region", &region(tile_bounds, true))
                document.add_element("GroundOverlay") do |overlay|
                  overlay.add_element("drawOrder") { |draw_order| draw_order.text = zoom }
                  overlay.add_element("Icon") do |icon|
                    icon.add_element("href") { |href| href.text = tile_png_name }
                  end
                  overlay.add_element("LatLonBox", &lat_lon_box(tile_bounds))
                end
                if zoom < max_zoom
                  indices.map do |index|
                    [ 2 * index, 2 * index + 1 ]
                  end.inject(:product).select do |subindices|
                    pyramid[zoom + 1][subindices]
                  end.each do |subindices|
                    document.add_element("NetworkLink", &network_link(pyramid[zoom + 1][subindices], "../../#{[ zoom+1, *subindices ].join ?/}.kml"))
                  end
                end
              end
            end
            File.write tile_kml_path, xml
            
            tile_png_path = index_dir + tile_png_name
            crops = indices.map { |index| index * TILE_SIZE }
            %Q[convert "#{tif_path}" -quiet +repage -crop #{TILE_SIZE}x#{TILE_SIZE}+#{crops.join ?+} +repage +dither -type PaletteBilevelMatte PNG8:"#{tile_png_path}"]
          end
        end.flatten.tap do |commands|
          commands.each.with_index do |command, index|
            $stdout << "\r  creating tile #{index + 1} of #{commands.length}"
            %x[#{command}]
          end
          puts
        end
        
        xml = REXML::Document.new
        xml << REXML::XMLDecl.new(1.0, "UTF-8")
        xml.add_element("kml", "xmlns" => "http://earth.google.com/kml/2.1") do |kml|
          kml.add_element("Document") do |document|
            document.add_element("LookAt") do |look_at|
              range_x = map.extents.first / 2.0 / Math::tan(FOV) / Math::cos(TILT)
              range_y = map.extents.last / Math::cos(FOV - TILT) / 2 / (Math::tan(FOV - TILT) + Math::sin(TILT))
              names_values = [ %w[longitude latitude], map.projection.reproject_to_wgs84(map.centre) ].transpose
              names_values << [ "tilt", TILT * 180.0 / Math::PI ] << [ "range", 1.2 * [ range_x, range_y ].max ] << [ "heading", -map.rotation ]
              names_values.each { |name, value| look_at.add_element(name) { |element| element.text = value } }
            end
            document.add_element("Name") { |name| name.text = map.name }
            document.add_element("Style", &style)
            document.add_element("NetworkLink", &network_link(pyramid[0][[0,0]], "0/0/0.kml"))
          end
        end
        kml_path = kmz_dir + "doc.kml"
        File.write kml_path, xml
        
        temp_kmz_path = temp_dir + "#{map.name}.kmz"
        Dir.chdir(kmz_dir) { %x[#{ZIP} -r "#{temp_kmz_path}" *] }
        FileUtils.cp temp_kmz_path, kmz_path
      end
    end
  end
  
  module Raster
    def self.build(config, map, ppi, svg_path, temp_dir, png_path)
      dimensions = map.dimensions_at(ppi)
      rasterise = config["rasterise"]
      case rasterise
      when /inkscape/i
        %x["#{rasterise}" --without-gui --file="#{svg_path}" --export-png="#{png_path}" --export-width=#{dimensions.first} --export-height=#{dimensions.last} --export-background="#FFFFFF" #{DISCARD_STDERR}]
      when /batik/
        args = %Q[-d "#{png_path}" -bg 255.255.255.255 -m image/png -w #{dimensions.first} -h #{dimensions.last} "#{svg_path}"]
        jar_path = Pathname.new(rasterise).expand_path + "batik-rasterizer.jar"
        java = config["java"] || "java"
        %x[#{java} -jar "#{jar_path}" #{args}]
      when /rsvg-convert/
        %x["#{rasterise}" --background-color white --format png --output "#{png_path}" --width #{dimensions.first} --height #{dimensions.last} "#{svg_path}"]
      when "qlmanage"
        square_svg_path = temp_dir + "square.svg"
        square_png_path = temp_dir + "square.svg.png"
        xml = REXML::Document.new(svg_path.read)
        millimetres = map.extents.map { |extent| 1000.0 * extent / map.scale }
        xml.elements["/svg"].attributes["width"] = "#{millimetres.max}mm"
        xml.elements["/svg"].attributes["height"] = "#{millimetres.max}mm"
        xml.elements["/svg"].attributes["viewBox"] = "0 0 #{millimetres.max} #{millimetres.max}"
        File.write square_svg_path, xml
        %x[qlmanage -t -s #{dimensions.max} -o "#{temp_dir}" "#{square_svg_path}"]
        %x[convert "#{square_png_path}" -crop #{dimensions.join ?x}+0+0 +repage "#{png_path}"]
      when /phantomjs/i
        js_path   = temp_dir + "rasterise.js"
        page_path = temp_dir + "rasterise.svg"
        out_path  = temp_dir + "rasterise.png"
        File.write js_path, %Q[
          var page = require('webpage').create();
          page.viewportSize = { width: 1, height: 1 };
          page.open('#{page_path}', function(status) {
              page.render('#{out_path}');
              phantom.exit();
          });
        ]
        test = REXML::Document.new
        test << REXML::XMLDecl.new(1.0, "utf-8")
        test.add_element("svg", "version" => 1.1, "baseProfile" => "full", "xmlns" => "http://www.w3.org/2000/svg", "width"  => "1in", "height" => "1in")
        page_path.open("w") { |file| test.write file }
        %x["#{rasterise}" "#{js_path}"]
        screen_ppi = %x[identify -format "%w" "#{out_path}"].to_f
        xml = REXML::Document.new(svg_path.read)
        svg = xml.elements["/svg"]
        %w[width height].each do |name|
          attribute = svg.attributes[name]
          svg.attributes[name] = attribute.sub /\d+(\.\d+)?/, (attribute.to_f * ppi / screen_ppi).to_s
        end
        xml.elements.each("//image[@xlink:href]") do |image|
          next if image.attributes["xlink:href"] =~ /^data:/
          image.attributes["xlink:href"] = Pathname.pwd + image.attributes["xlink:href"]
        end
        page_path.open("w") { |file| xml.write file }
        %x["#{rasterise}" "#{js_path}"]
        # TODO: crop to exact size
        FileUtils.cp out_path, png_path
      else
        abort("Error: specify either phantomjs, inkscape or qlmanage as your rasterise method (see README).")
      end
      case
      when config["dither"] && config["gimp"]
        script_path = temp_dir + "dither.scm"
        File.write script_path, %Q[
          (let*
            (
              (image (car (gimp-file-load RUN-NONINTERACTIVE "#{png_path}" "#{png_path}")))
              (drawable (car (gimp-image-get-active-layer image)))
            )
            (gimp-image-convert-indexed image FSLOWBLEED-DITHER MAKE-PALETTE 256 FALSE FALSE "")
            (gimp-file-save RUN-NONINTERACTIVE image drawable "#{png_path}" "#{png_path}")
            (gimp-quit TRUE)
          )
        ]
        %x[mogrify -background white -alpha Remove "#{png_path}"]
        %x[cat "#{script_path}" | "#{config['gimp']}" -c -d -f -i -b -]
        %x[mogrify -units PixelsPerInch -density #{ppi} "#{png_path}"]
      when config["dither"]
        %x[mogrify -units PixelsPerInch -density #{ppi} -background white -alpha Remove -type Palette -dither Riemersma -define PNG:exclude-chunk=bkgd "#{png_path}"]
      else
        %x[mogrify -units PixelsPerInch -density #{ppi} -background white -alpha Remove "#{png_path}"]
      end
    end
  end
  
  module PSD
    def self.build(config, map, ppi, svg_path, composite_png_path, temp_dir, psd_path)
      xml = REXML::Document.new(svg_path.read)
      xml.elements["/svg/rect"].remove
      xml.elements.delete_all("/svg/g[@id]").map do |group|
        id = group.attributes["id"]
        puts "    Generating layer: #{id}"
        layer_svg_path, layer_png_path = %w[svg png].map { |ext| temp_dir + [ map.name, id, ext ].join(?.) }
        xml.elements["/svg"].add group
        layer_svg_path.open("w") { |file| xml.write file }
        group.remove
        Raster.build(config, map, ppi, layer_svg_path, temp_dir, layer_png_path)
        # Dodgy; Make sure there's a coloured pixel or imagemagick won't fill in the G and B channels in the PSD:
        %x[mogrify -label #{id} -fill "#FFFFFEFF" -draw 'color 0,0 point' "#{layer_png_path}"]
        layer_png_path
      end.unshift(composite_png_path).map do |layer_png_path|
        %Q[#{OP} "#{layer_png_path}" -units PixelsPerInch #{CP}]
      end.join(?\s).tap do |sequence|
        %x[convert #{sequence} "#{psd_path}"]
      end
    end
  end
  
  module PDF
    def self.build(config, map, svg_path, temp_dir, pdf_path)
      rasterise = config["rasterise"]
      case rasterise
      when /inkscape/i
        %x["#{rasterise}" --without-gui --file="#{svg_path}" --export-pdf="#{pdf_path}" #{DISCARD_STDERR}]
      when /batik/
        jar_path = Pathname.new(rasterise).expand_path + "batik-rasterizer.jar"
        java = config["java"] || "java"
        %x[#{java} -jar "#{jar_path}" -d "#{pdf_path}" -bg 255.255.255.255 -m application/pdf "#{svg_path}"]
      when /rsvg-convert/
        %x["#{rasterise}" --background-color white --format pdf --output "#{pdf_path}" "#{svg_path}"]
      when "qlmanage"
        raise NoVectorPDF.new("qlmanage")
      when /phantomjs/
        xml = REXML::Document.new(svg_path.read)
        width, height = %w[width height].map { |name| xml.elements["/svg"].attributes[name] }
        js_path = temp_dir + "makepdf.js"
        File.write js_path, %Q[
          var page = require('webpage').create();
          page.paperSize = { width: '#{width}', height: '#{height}' };
          page.open('#{svg_path.to_s.gsub(?', "\\\\\'")}', function(status) {
              page.render('#{pdf_path.to_s.gsub(?', "\\\\\'")}');
              phantom.exit();
          });
        ]
        %x["#{rasterise}" "#{js_path}"]
      else
        abort("Error: specify either inkscape or phantomjs as your rasterise method (see README).")
      end
    end
  end
  
  def self.run
    default_config = YAML.load(CONFIG)
    
    %w[bounds.kml bounds.gpx].map do |filename|
      Pathname.pwd + filename
    end.find(&:exist?).tap do |bounds_path|
      default_config["bounds"] = bounds_path if bounds_path
    end
    
    unless Pathname.new("nswtopo.cfg").expand_path.exist?
      if default_config["bounds"]
        puts "No nswtopo.cfg configuration file found. Using #{default_config['bounds'].basename} as map bounds."
      else
        abort "Error: could not find any configuration file (nswtopo.cfg) or bounds file (bounds.kml)."
      end
    end
    
    config = [ Pathname.new(__FILE__).realdirpath.dirname, Pathname.pwd ].map do |dir_path|
      dir_path + "nswtopo.cfg"
    end.select(&:exist?).map do |config_path|
      begin
        YAML.load config_path.read
      rescue ArgumentError, SyntaxError => e
        abort "Error in configuration file: #{e.message}"
      end
    end.inject(default_config, &:deep_merge)
    
    builtins = YAML.load %q[---
canvas:
  class: CanvasSource
relief:
  class: ReliefSource
  altitude: 45
  azimuth: 315
  exaggeration: 2
  resolution: 30.0
  opacity: 0.3
  highlights: 20
  median: 30.0
  bilateral: 5
grid:
  class: GridSource
  interval: 1000
  label-spacing: 5
  stroke: black
  stroke-width: 0.1
  boundary:
    stroke: gray
  labels:
    margin: 0.8
    dupe: outline
    outline:
      stroke: white
      fill: none
      stroke-width: 0.3
      stroke-opacity: 0.75
    font-family: "'Arial Narrow', sans-serif"
    font-size: 2.75
    stroke: none
    fill: black
declination:
  class: DeclinationSource
  spacing: 1000
  arrows: 150
  stroke: darkred
  stroke-width: 0.1
controls:
  class: ControlSource
  diameter: 7.0
  stroke: "#880088"
  stroke-width: 0.2
  water:
    stroke: blue
  labels:
    dupe: outline
    outline:
      stroke: white
      fill: none
      stroke-width: 0.25
      stroke-opacity: 0.75
    position: [ aboveright, belowright, aboveleft, belowleft, right, left, above, below ]
    font-family: sans-serif
    font-size: 4.9
    stroke: none
    fill: "#880088"
]
    
    config["include"] = [ *config["include"] ]
    if config["include"].empty?
      config["include"] << "nsw/topographic"
      puts "No layers specified. Adding nsw/topographic by default."
    end
    
    %w[controls.gpx controls.kml].map do |filename|
      Pathname.pwd + filename
    end.find(&:file?).tap do |control_path|
      if control_path
        config["include"] |= [ "controls" ]
        config["controls"] ||= {}
        config["controls"]["path"] ||= control_path.to_s
      end
    end
    
    config["include"].unshift "canvas" if Pathname.new("canvas.png").expand_path.exist?
    
    map = Map.new(config)
    
    puts "Map details:"
    puts "  name: #{map.name}"
    puts "  size: %imm x %imm" % map.extents.map { |extent| 1000 * extent / map.scale }
    puts "  scale: 1:%i" % map.scale
    puts "  rotation: %.1f degrees" % map.rotation
    puts "  extent: %.1fkm x %.1fkm" % map.extents.map { |extent| 0.001 * extent }
    
    sources = {}
    
    [ *config["import"] ].reverse.map do |file_or_hash|
      [ *file_or_hash ].flatten
    end.map do |file_or_path, name|
      [ Pathname.new(file_or_path).expand_path, name ]
    end.each do |path, name|
      name ||= path.basename(path.extname).to_s
      sources.merge! name => { "class" => "ImportSource", "path" => path.to_s }
    end
    
    config["include"].map do |name_or_path_or_hash|
      [ *name_or_path_or_hash ].flatten
    end.each do |name_or_path, resolution|
      path = Pathname.new(name_or_path).expand_path
      name, params = case
      when builtins[name_or_path]
        [ name_or_path, builtins[name_or_path] ]
      when %w[.kml .gpx].include?(path.extname.downcase) && path.file?
        params = YAML.load %Q[---
          class: OverlaySource
          path: #{path}
        ]
        [ path.basename(path.extname).to_s, params ]
      else
        yaml = [ Pathname.pwd, Pathname.new(__FILE__).realdirpath.dirname + "sources", URI.parse(GITHUB_SOURCES) ].map do |root|
          root + "#{name_or_path}.yml"
        end.inject(nil) do |memo, path|
          memo ||= path.read rescue nil
        end
        abort "Error: couldn't find source for '#{name_or_path}'" unless yaml
        [ name_or_path.gsub(?/, SEGMENT), YAML.load(yaml) ]
      end
      params.merge! "resolution" => resolution if resolution
      sources.merge! name => params
    end
    
    sources.each do |name, params|
      config.map do |key, value|
        [ key.match(%r{#{name}#{SEGMENT}(.+)}), value ]
      end.select(&:first).map do |match, layer_params|
        { match[1] => layer_params }
      end.inject(&:merge).tap do |layers_params|
        params.deep_merge! layers_params if layers_params
      end
    end
    
    sources.select do |name, params|
      config[name]
    end.each do |name, params|
      params.deep_merge! config[name]
    end
    
    sources["relief"]["masks"] = sources.map do |name, params|
      [ *params["relief-masks"] ].map { |sublayer| [ name, sublayer ].join SEGMENT }
    end.inject(&:+) if sources["relief"]
    
    config["contour-interval"].tap do |interval|
      interval ||= map.scale < 40000 ? 10 : 20
      sources.each do |name, params|
        params["exclude"] = [ *params["exclude"] ]
        [ *params["intervals-contours"] ].select do |candidate, sublayers|
          candidate != interval
        end.map(&:last).each do |sublayers|
          params["exclude"] += [ *sublayers ]
        end
      end
    end
    
    config["exclude"] = [ *config["exclude"] ].map { |name| name.gsub ?/, SEGMENT }
    config["exclude"].each do |source_or_layer_name|
      sources.delete source_or_layer_name
      sources.each do |name, params|
        match = source_or_layer_name.match(%r{^#{name}#{SEGMENT}(.+)})
        params["exclude"] << match[1] if match
      end
    end
    
    label_params = sources.map do |name, params|
      [ name, params["labels"] ]
    end.select(&:last)
    
    sources.find do |name, params|
      params.fetch("min-version", NSWTOPO_VERSION).to_s > NSWTOPO_VERSION
    end.tap do |name, params|
      abort "Error: map source '#{name}' requires a newer version of this software; please upgrade." if name
    end
    
    sources = sources.map do |name, params|
      NSWTopo.const_get(params.delete "class").new(name, params)
    end
    
    sources.reject(&:exist?).recover(InternetError, ServerError, BadLayerError).each do |source|
      source.create(map)
    end
    
    return if config["no-output"]
    
    svg_name = "#{map.name}.svg"
    svg_path = Pathname.pwd + svg_name
    xml = svg_path.exist? ? REXML::Document.new(svg_path.read) : map.xml
    
    removals = config["exclude"].select do |name|
      predicate = "@id='#{name}' or starts-with(@id,'#{name}#{SEGMENT}')"
      xml.elements["/svg/g[#{predicate}] | svg/defs/[#{predicate}]"]
    end
    
    updates = sources.reject do |source|
      source.path ? FileUtils.uptodate?(svg_path, [ *source.path ]) : xml.elements["/svg/g[@id='#{source.name}' or starts-with(@id,'#{source.name}#{SEGMENT}')]"]
    end
    
    Dir.mktmppath do |temp_dir|
      tmp_svg_path = temp_dir + svg_name
      tmp_svg_path.open("w") do |file|
        if updates.any? do |source|
          source.respond_to? :labels
        end || removals.any? do |name|
          xml.elements["/svg/g[@id='labels#{SEGMENT}#{name}']"]
        end then
          label_source = LabelSource.new "labels", Hash[label_params]
        end
        
        config["exclude"].map do |name|
          predicate = "@id='#{name}' or starts-with(@id,'#{name}#{SEGMENT}') or @id='labels#{SEGMENT}#{name}' or starts-with(@id,'labels#{SEGMENT}#{name}#{SEGMENT}')"
          xpath = "/svg/g[#{predicate}] | svg/defs/[#{predicate}]"
          if xml.elements[xpath]
            puts "Removing: #{name}"
            xml.elements.each(xpath, &:remove)
          end
        end
        
        [ *updates, *label_source ].each do |source|
          begin
            puts "Compositing: #{source.name}"
            predicate = "@id='#{source.name}' or starts-with(@id,'#{source.name}#{SEGMENT}')"
            xml.elements.each("/svg/g[#{predicate}]/*", &:remove)
            xml.elements.each("/svg/defs/[#{predicate}]", &:remove)
            if source == label_source
              sources.each { |source| label_source.add(source, map) }
              label_source.render_svg(map) do |sublayer|
                id = [ label_source.name, *sublayer ].join(SEGMENT)
                xml.elements["/svg/g[@id='#{id}']"] || xml.elements["/svg"].add_element("g", "id" => id, "style" => "opacity:1")
              end
            elsif xml.elements["/svg/g[@id='#{source.name}' or starts-with(@id,'#{source.name}#{SEGMENT}')]"]
              source.render_svg(map) do |sublayer|
                id = [ source.name, *sublayer ].join(SEGMENT)
                xml.elements["/svg/g[@id='#{id}']"].tap do |group|
                  source.params["exclude"] << sublayer unless group
                end
              end
            else
              before, after = sources.map(&:name).inject([[]]) do |memo, name|
                name == source.name ? memo << [] : memo.last << name
                memo
              end
              neighbour = xml.elements.collect("/svg/g[@id]") do |sibling|
                sibling if [ *after ].any? do |name|
                  sibling.attributes["id"] == name || sibling.attributes["id"].start_with?("#{name}#{SEGMENT}")
                end
              end.compact.first
              source.render_svg(map) do |sublayer|
                id = [ source.name, *sublayer ].join(SEGMENT)
                REXML::Element.new("g").tap do |group|
                  group.add_attributes "id" => id, "style" => "opacity:1"
                  neighbour ? xml.elements["/svg"].insert_before(neighbour, group) : xml.elements["/svg"].add_element(group)
                end
              end
            end
            puts "Styling: #{source.name}"
            source.rerender(xml, map)
          rescue BadLayerError => e
            puts "Failed to render #{source.name}: #{e.message}"
          end
        end
        
        xml.elements.each("/svg/g[*]") { |group| group.add_attribute("inkscape:groupmode", "layer") }
        
        if config["check-fonts"]
          fonts_needed = xml.elements.collect("//[@font-family]") do |element|
            element.attributes["font-family"].gsub(/[\s\-\'\"]/, "")
          end.uniq
          fonts_present = %x[identify -list font].scan(/(family|font):(.*)/i).map(&:last).flatten.map do |family|
            family.gsub(/[\s\-]/, "")
          end.uniq
          fonts_missing = fonts_needed - fonts_present
          if fonts_missing.any?
            puts "Your system does not include some fonts used in #{svg_name}. (Inkscape will not render these fonts correctly.)"
            fonts_missing.sort.each { |family| puts "  #{family}" }
          end
        end
        
        formatter = REXML::Formatters::Pretty.new
        formatter.compact = true
        formatter.write xml, file
      end
      FileUtils.cp tmp_svg_path, svg_path
    end if updates.any? || removals.any?
    
    formats = [ *config["formats"] ].map { |format| [ *format ].flatten }.inject({}) { |memo, (format, option)| memo.merge format => option }
    formats["prj"] = %w[wkt_all proj4 wkt wkt_simple wkt_noct wkt_esri mapinfo xml].delete(formats["prj"]) || "proj4" if formats.include? "prj"
    formats["png"] ||= nil if formats.include? "map"
    (formats.keys & %w[png tif gif jpg kmz psd]).each do |format|
      formats[format] ||= config["ppi"]
      formats["#{format[0]}#{format[2]}w"] = formats[format] if formats.include? "prj"
    end
    
    outstanding = (formats.keys & %w[png tif gif jpg kmz psd pdf pgw tfw gfw jgw map prj]).reject do |format|
      FileUtils.uptodate? "#{map.name}.#{format}", [ svg_path ]
    end
    
    Dir.mktmppath do |temp_dir|
      outstanding.group_by do |format|
        formats[format]
      end.each do |ppi, group|
        raster_path = temp_dir + "#{map.name}.#{ppi}.png"
        if (group & %w[png tif gif jpg kmz psd]).any? || (ppi && group.include?("pdf"))
          dimensions = map.dimensions_at(ppi)
          puts "Generating raster: %ix%i (%.1fMpx) @ %i ppi" % [ *dimensions, 0.000001 * dimensions.inject(:*), ppi ]
          Raster.build config, map, ppi, svg_path, temp_dir, raster_path
        end
        group.each do |format|
          begin
            puts "Generating #{map.name}.#{format}"
            output_path = temp_dir + "#{map.name}.#{format}"
            case format
            when "png"
              FileUtils.cp raster_path, output_path
            when "tif"
              tfw_path = Pathname.new("#{raster_path}w")
              map.write_world_file tfw_path, map.resolution_at(ppi)
              %x[gdal_translate -a_srs "#{map.projection}" -co "PROFILE=GeoTIFF" -co "COMPRESS=DEFLATE" -co "ZLEVEL=9" -co "TILED=YES" -mo "TIFFTAG_RESOLUTIONUNIT=2" -mo "TIFFTAG_XRESOLUTION=#{ppi}" -mo "TIFFTAG_YRESOLUTION=#{ppi}" -mo "TIFFTAG_SOFTWARE=nswtopo" -mo "TIFFTAG_DOCUMENTNAME=#{map.name}" "#{raster_path}" "#{output_path}"]
            when "gif", "jpg"
              %x[convert "#{raster_path}" "#{output_path}"]
            when "kmz"
              KMZ.build map, ppi, raster_path, output_path
            when "psd"
              PSD.build config, map, ppi, svg_path, raster_path, temp_dir, output_path
            when "pdf"
              ppi ? %x[convert "#{raster_path}" "#{output_path}"] : PDF.build(config, map, svg_path, temp_dir, output_path)
            when "pgw", "tfw", "gfw", "jgw"
              map.write_world_file output_path, map.resolution_at(ppi)
            when "map"
              map.write_oziexplorer_map output_path, map.name, "#{map.name}.png", formats["png"]
            when "prj"
              File.write output_path, map.projection.send(formats["prj"])
            end
            FileUtils.cp output_path, Dir.pwd
          rescue NoVectorPDF => e
            puts "Error: can't generate vector PDF with #{e.message}. Specify a ppi for the PDF or use inkscape. (See README.)"
          end
        end
      end
    end unless outstanding.empty?
  end
end

Signal.trap("INT") do
  abort "\nHalting execution. Run the script again to resume."
end

if File.identical?(__FILE__, $0)
  NSWTopo.run
end

# TODO: switch to Open3 for shelling out
# TODO: add nodata transparency in vegetation source?
# TODO: remove linked images from PDF output?
# TODO: check georeferencing of aerial-google, aerial-nokia

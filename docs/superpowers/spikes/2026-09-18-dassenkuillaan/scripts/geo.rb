# Throwaway geometry helpers for the spike: GeoJSON rings, the mijnstreek frame, and a
# local (row-aligned) frame for a cluster of parts. Pure Ruby, no Rails.
require "json"

module Spike
  ORIGIN_X = 185_000.0
  ORIGIN_Y = 330_000.0

  # RD easting/northing -> game x/z (east, south).
  def self.to_game(x, y) = [ x - ORIGIN_X, -(y - ORIGIN_Y) ]

  # The exterior ring of a GeoJSON polygon, in game coordinates, closing point dropped.
  def self.ring(geojson)
    coords = geojson["type"] == "MultiPolygon" ? geojson["coordinates"].max_by { |poly| shoelace(poly[0]) } : geojson["coordinates"]
    pts = coords[0].map { |x, y| to_game(x, y) }
    pts.pop if pts.first == pts.last
    pts
  end

  def self.shoelace(pts)
    pts.each_with_index.sum { |(x1, y1), i| x2, y2 = pts[(i + 1) % pts.length]; x1 * y2 - x2 * y1 }.abs / 2.0
  end

  # A row-aligned local frame: x runs along `axis` (unit vector in game xz), z across it,
  # so that local x = EAST and local z = SOUTH in the same handedness the generator
  # assumes (EAST x SOUTH points down). `origin` is a game point.
  class Frame
    attr_reader :origin, :yaw, :u, :v

    def initialize(origin:, yaw:)
      @origin = origin
      @yaw = yaw
      @u = [ Math.cos(yaw), Math.sin(yaw) ]
      @v = [ -Math.sin(yaw), Math.cos(yaw) ]
    end

    def to_local(gx, gz)
      dx = gx - origin[0]
      dz = gz - origin[1]
      [ dx * u[0] + dz * u[1], dx * v[0] + dz * v[1] ]
    end

    def to_world(lx, lz)
      [ origin[0] + lx * u[0] + lz * v[0], origin[1] + lx * u[1] + lz * v[1] ]
    end

    # The same frame, with its origin moved so every one of `points` (game xz) has
    # non-negative local coordinates.
    def normalised(points)
      locals = points.map { |gx, gz| to_local(gx, gz) }
      min_x = locals.map(&:first).min
      min_z = locals.map(&:last).min
      Frame.new(origin: to_world(min_x, min_z), yaw: yaw)
    end

    # Turned half round: the same axis, the other way, which swaps which long side is z = 0.
    def flipped = Frame.new(origin: origin, yaw: yaw + Math::PI)
  end

  # The axis of an oriented envelope ring (4 points): the direction of its longer edge.
  def self.axis_of(env_ring)
    a, b, c = env_ring[0], env_ring[1], env_ring[2]
    e1 = [ b[0] - a[0], b[1] - a[1] ]
    e2 = [ c[0] - b[0], c[1] - b[1] ]
    long = Math.hypot(*e1) >= Math.hypot(*e2) ? e1 : e2
    Math.atan2(long[1], long[0])
  end

  # Distance from a point to a polyline, both in game coordinates.
  def self.distance_to_polyline(px, pz, line)
    line.each_cons(2).map { |(x1, z1), (x2, z2)| distance_to_segment(px, pz, x1, z1, x2, z2) }.min
  end

  def self.distance_to_segment(px, pz, x1, z1, x2, z2)
    dx = x2 - x1
    dz = z2 - z1
    l2 = dx * dx + dz * dz
    t = l2.zero? ? 0.0 : (((px - x1) * dx + (pz - z1) * dz) / l2).clamp(0.0, 1.0)
    Math.hypot(px - (x1 + t * dx), pz - (z1 + t * dz))
  end

  # Loads window.json + rows.json into clusters ready for the generator.
  class Data
    attr_reader :parts, :clusters, :roads, :adjacency

    def initialize(dir)
      window = JSON.parse(File.read(File.join(dir, "window.json")))
      @parts = window["parts"].to_h { |p| [ p["id"], p ] }
      @adjacency = window["adjacency"]
      @roads = window["roads"].map { |r| r.merge("line" => r["geom"]["coordinates"].map { |x, y| Spike.to_game(x, y) }) }
      @clusters = JSON.parse(File.read(File.join(dir, "rows.json")))
    end

    def parts_of(pand) = parts.values.select { |p| p["pand"] == pand }
    def shared(a_id, b_id)
      a = parts[a_id]["source_id"]
      b = parts[b_id]["source_id"]
      adjacency.find { |x| x["a"] == a && x["b"] == b }&.dig("shared") || 0.0
    end
  end
end

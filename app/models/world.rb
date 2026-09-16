# A persistent world: its coordinate frame, the grids laid over it, and the hard edges
# beyond which nothing can travel.
#
# This is the only place the two grids are reconciled. Terrain samples on one spacing and
# objects stream on another, and both have to nest inside a tile exactly or the world
# develops seams -- neighbouring tiles that disagree along a shared edge, or a chunk that
# straddles two tiles and belongs to neither. Both are validated rather than commented.
class World < ApplicationRecord
  has_many :terrain_tiles, dependent: :delete_all
  has_many :world_objects, dependent: :delete_all
  has_many :matches, dependent: :destroy

  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9-]+\z/ }
  validates :name, presence: true
  validates :tile_size, :height_step, :chunk_size, numericality: { greater_than: 0 }
  validate :grids_nest

  def self.[](slug)
    find_by!(slug: slug)
  end

  # Samples per tile edge. One more than the number of cells, because neighbouring tiles
  # share their edge samples -- that shared row is what keeps the seam flat.
  def height_n
    tile_size / height_step + 1
  end

  def chunks_per_tile
    tile_size / chunk_size
  end

  # What is in here, in the world's own words: "ground, 3 crates, a pillar". Reads from
  # the objects rather than from a description someone has to remember to update.
  def summary
    # Fixed geometry first, then what can be broken -- "ground, 3 crates, pillar" rather
    # than whatever order the rows happen to come back in.
    counts = world_objects.order(kind: :desc, name: :asc).map(&:role).tally
    return "empty" if counts.empty?

    counts.map { |role, count| count > 1 ? "#{count} #{role}s" : role }.join(", ")
  end

  # `bounds` is [min_x, min_z, max_x, max_z] in game metres -- the hard edges of the
  # world, beyond which nothing can travel.
  def extent
    min_x, min_z, max_x, max_z = bounds
    [ max_x - min_x, max_z - min_z ]
  end

  # The payload the client builds a world out of. Static rows become fixed geometry,
  # props become things that can be knocked about and broken; buildings are generated
  # from their recipes and do not appear here.
  def scene
    Game::Scene.new(
      name: name,
      gravity: Game::Vector3.new(0, gravity, 0),
      bounds: bounds,
      bodies: world_objects.where(kind: "static").order(:id).map(&:to_static_body),
      props: world_objects.where(kind: "prop").order(:id).map(&:to_prop),
      buildings: world_objects.where(kind: "building").order(:id).map(&:to_building),
      spawns: spawn_points
    )
  end

  def spawn_points
    spawns.map do |spawn|
      x, y, z = spawn.fetch("position")
      Game::Spawn.new(position: Game::Vector3.new(x, y, z), yaw: spawn.fetch("yaw", 0.0))
    end
  end

  def frame
    Game::Terrain::Frame.new(
      origin_x: origin_x, origin_y: origin_y, origin_z: origin_z, srid: srid,
      tile_size: tile_size, height_step: height_step, chunk_size: chunk_size
    )
  end

  # "What is the ground height here?" for tests and seeders. The client has its own port
  # of this, and the parity test holds the two to the same answer.
  def sampler(fallback: 0.0)
    Game::Terrain::Sampler.new(frame: frame, tiles: terrain_tiles.map(&:tile), fallback: fallback)
  end

  private
    def grids_nest
      return if tile_size.to_i.zero?

      if height_step.to_i.positive? && !(tile_size % height_step).zero?
        errors.add(:height_step, "must divide tile_size, or tiles disagree along shared edges")
      end

      return unless chunk_size.to_i.positive? && !(tile_size % chunk_size).zero?

      errors.add(:chunk_size, "must divide tile_size, or a chunk straddles two tiles")
    end
end

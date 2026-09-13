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

  def frame
    Game::Terrain::Frame.new(
      origin_x: origin_x, origin_y: origin_y, origin_z: origin_z, srid: srid,
      tile_size: tile_size, height_step: height_step, chunk_size: chunk_size
    )
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

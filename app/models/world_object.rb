# Something standing in the world: a building, a piece of static geometry, or a prop.
#
# A building stores the recipe it is generated from and never its pieces. Generating is
# deterministic, so the pieces can be rebuilt identically on demand -- which is the only
# reason a thousand buildings is a thousand rows rather than a hundred and sixty thousand.
class WorldObject < ApplicationRecord
  KINDS = %w[building static prop].freeze

  belongs_to :world
  has_many :object_damages, dependent: :delete_all

  validates :kind, inclusion: { in: KINDS }
  # The unique index is the real guarantee, since it also survives a race. This is here so
  # a seeder that collides gets told which name rather than a constraint violation.
  validates :name, presence: true, uniqueness: { scope: :world_id }
  validates :piece_count, :storey_count, numericality: { greater_than_or_equal_to: 0 }
  validate :fits_within_a_chunk

  scope :in_chunk, ->(cx, cz) { where(cx: cx, cz: cz) }

  def building? = kind == "building"

  private
    # The chunk holding the anchor owns the object; `radius` is how far it reaches beyond
    # that anchor. Keeping it under one chunk is what guarantees a three-by-three ring
    # around the player contains everything that could intrude on it.
    def fits_within_a_chunk
      return if world.blank? || radius.blank?
      return if radius < world.chunk_size

      errors.add(:radius, "must be smaller than the #{world.chunk_size}m chunk size")
    end
end

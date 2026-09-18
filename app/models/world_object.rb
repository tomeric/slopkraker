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

  # Generated on demand and memoised. A building's pieces are never stored -- generating
  # is deterministic, so they can be rebuilt identically whenever they are wanted, which
  # is what keeps a thousand buildings a thousand rows rather than a quarter of a million.
  def surface_set
    @surface_set ||= Game::Building::Generator.call(recipe)
  end

  def to_building
    {
      id: id,
      name: name,
      o: position.to_a,
      yaw: yaw,
      # What the debug overlay labels the building with. An imported recipe names its
      # category and the source records it was built from; a hand-made one has only its
      # kind, and the overlay falls back to the object's own id.
      category: recipe["category"] || role,
      pands: recipe["pands"],
      # Which colours it is drawn in. A hand-made recipe names none and gets the default,
      # which is tuned to today's colours so the four worlds look like themselves.
      palette: recipe["palette"] || Game::Palettes::DEFAULT.to_s,
      # Rings the client drapes as lawn, in the building's rotated frame like its surfaces;
      # nothing for a building without gardens, so the four worlds gain no key.
      lawns: Game::Building::Generator.lawns(recipe).presence
    }.compact.merge(surface_set.to_spec)
  end

  # `kind` says how a thing is stored and simulated; `recipe["kind"]` says what it is --
  # ground, wall, crate, pillar. The client uses the latter to pick a colour, decide
  # whether to cast a shadow and label a hit, so the two taxonomies are deliberately
  # separate rather than one column trying to be both.
  def role
    recipe["kind"] || kind
  end

  def to_static_body
    Game::StaticBody.new(
      name: name, kind: role,
      position: position, size: size, rotation: rotation,
      colour: recipe.fetch("colour", "#4a5159"),
      friction: recipe.fetch("friction", 1.0),
      restitution: recipe.fetch("restitution", 0.05)
    )
  end

  def to_prop
    Game::DestructibleProp.new(
      name: name, kind: role,
      position: position, size: size, rotation: rotation,
      mass: recipe.fetch("mass"), health: recipe.fetch("health"),
      hardness: recipe.fetch("hardness", 0.0),
      debris_count: recipe.fetch("debris_count", 6),
      colour: recipe.fetch("colour", "#b5651d")
    )
  end

  def position
    Game::Vector3.new(x, y, z)
  end

  def size
    w, h, d = recipe.fetch("size")
    Game::Vector3.new(w, h, d)
  end

  # Stored as yaw plus an optional explicit pitch, because that is how a ramp is actually
  # described. A full quaternion in the recipe wins if one is given.
  def rotation
    if (quat = recipe["rotation"])
      return Game::Quaternion.new(*quat)
    end

    Game::Quaternion.from_yaw_pitch(yaw, recipe.fetch("pitch", 0.0))
  end

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

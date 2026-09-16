# One 500m square of heightfield. The blob is the payload the browser gets served
# verbatim, so the encoding lives in Game::Terrain::HeightsCodec beside the sampler that
# reads it rather than here.
class TerrainTile < ApplicationRecord
  belongs_to :world

  validates :tx, :tz, :base_cm, :min_cm, :max_cm, presence: true
  validate :blob_is_the_right_size

  # Metres above the world origin, decoded. Kept out of the hot path: the sampler works on
  # the raw blob, and this exists for seeding, tests and inspection.
  def heights_m
    Game::Terrain::HeightsCodec.unpack(heights, base_cm)
  end

  def tile
    Game::Terrain::Tile.new(
      tx: tx, tz: tz, n: world.height_n, base_cm: base_cm, blob: heights, frame: world.frame
    )
  end

  # Twelve hex characters of the bytes themselves. This, not the world's content_digest,
  # is what goes in the tile URL: the URL is cached as immutable for a year, so it has to
  # change exactly when the bytes do, and a hand-written world digest nobody updates would
  # keep serving old ground through every change to the function that made it.
  def digest
    Digest::SHA256.hexdigest(heights)[0, 12]
  end

  # What the spec ships about this tile: enough to size things without decoding it, and
  # where to fetch it. The URL is built here rather than in the PORO manifest because the
  # Active Record model is the boundary to Rails; Game::Terrain sees only a string.
  def manifest_entry
    {
      tx: tx, tz: tz, base_cm: base_cm, min_cm: min_cm, max_cm: max_cm,
      url: Rails.application.routes.url_helpers.world_tile_path(world.slug, digest, tx, tz)
    }
  end

  private
    def blob_is_the_right_size
      return if heights.blank? || world.blank?

      expected = world.height_n**2 * Game::Terrain::HeightsCodec::BYTES_PER_SAMPLE
      return if heights.bytesize == expected

      errors.add(:heights, "is #{heights.bytesize} bytes, expected #{expected} for a #{world.height_n} square")
    end
end

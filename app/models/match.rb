# One session's worth of damage to a world. The world itself is pristine and shared; what
# players break is scoped here, so a new match starts with the city standing.
class Match < ApplicationRecord
  # Mirrors ArenaChannel's own sanitising of the match name.
  KEY_FORMAT = /\A[a-zA-Z0-9_-]{1,32}\z/

  belongs_to :world
  has_many :object_damages, dependent: :delete_all

  validates :key, presence: true, uniqueness: true, format: { with: KEY_FORMAT }

  scope :stale, ->(before) { where(last_active_at: ...before) }

  def self.start(key:, world:)
    create_with(world: world, started_at: Time.current, last_active_at: Time.current)
      .find_or_create_by!(key: key)
  end

  # Destruction is authoritative in exactly one process, and this is how a process says so.
  # In a single-process deployment it always succeeds -- which is the point: the path is
  # exercised on every match rather than only on the day it first matters.
  #
  # A claim that has gone quiet for longer than `stale_after` is up for grabs, so a crashed
  # process does not take its matches with it.
  def claim(holder, stale_after: 5.minutes)
    cutoff = stale_after.ago
    claimed = self.class.where(id: id)
      .where(authority: [ nil, holder ])
      .or(self.class.where(id: id).where(authority_claimed_at: ...cutoff))
      .update_all(authority: holder, authority_claimed_at: Time.current)

    reload if claimed.positive?
    claimed.positive?
  end

  def authoritative?(holder)
    authority == holder
  end
end

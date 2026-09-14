# What one match has done to one object. Created lazily, on the first hit that lands, so
# an untouched world costs nothing.
#
# `broken_pieces` is the bitset and `broken_count` its population, denormalised so a resync
# can report how wrecked a building is without decoding the blob. Not called `destroyed`:
# that name collides with Active Record's own `destroyed?` and the collision is fatal --
# the model cannot even be instantiated.
#
# Destruction is monotone in both directions it can move: a piece goes standing to broken
# and never back, and a collapse goes nowhere or downward. That is what lets a client
# predict a break and never have to undo one, and what makes every server message
# idempotent.
class ObjectDamage < ApplicationRecord
  belongs_to :match
  belongs_to :world_object

  validates :broken_count, numericality: { greater_than_or_equal_to: 0 }
end

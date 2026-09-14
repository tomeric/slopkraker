# `destroyed` collides with Active Record's own `destroyed?`, and the collision is fatal
# rather than cosmetic: defining the attribute raises DangerousAttributeError, so the model
# cannot be instantiated at all. The original migration was never exercised -- nothing had
# read or written object_damages until damage became server-authoritative -- so it went
# unnoticed until the first row was built.
#
# Renamed to match what the rest of the system already calls it. The client sends `breaks`
# and calls its own method `breakCell`; the server had one table saying `destroyed` for the
# same idea.
class RenameObjectDamageBitset < ActiveRecord::Migration[8.1]
  def change
    rename_column :object_damages, :destroyed, :broken_pieces
    rename_column :object_damages, :destroyed_count, :broken_count
  end
end

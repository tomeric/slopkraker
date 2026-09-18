# Roads are drawn, not simulated: polylines the client drapes on the terrain as one mesh,
# with no colliders. A world without them has an empty list, never nil.
class AddRoadsToWorlds < ActiveRecord::Migration[8.1]
  def change
    add_column :worlds, :roads, :json, null: false, default: []
  end
end

# A collapse used to be one storey per building. A terrace is several dwellings and a
# church several parts, each of which stands or falls on its own, so the storey a
# building has come down from is now a map per bay. The single house of the four
# hand-made worlds is bay 0.
class CollapsePerBay < ActiveRecord::Migration[8.1]
  def up
    add_column :object_damages, :collapsed, :json, null: false, default: {}
    execute "UPDATE object_damages SET collapsed = json_object('0', collapsed_from) WHERE collapsed_from IS NOT NULL"
    remove_column :object_damages, :collapsed_from
  end

  def down
    add_column :object_damages, :collapsed_from, :integer
    execute "UPDATE object_damages SET collapsed_from = json_extract(collapsed, '$.\"0\"')"
    remove_column :object_damages, :collapsed
  end
end

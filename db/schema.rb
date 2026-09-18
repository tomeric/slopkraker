# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_18_120000) do
  create_table "matches", force: :cascade do |t|
    t.string "authority"
    t.datetime "authority_claimed_at"
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "last_active_at", null: false
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.integer "world_id", null: false
    t.index ["key"], name: "index_matches_on_key", unique: true
    t.index ["last_active_at"], name: "index_matches_on_last_active_at"
    t.index ["world_id"], name: "index_matches_on_world_id"
  end

  create_table "object_damages", force: :cascade do |t|
    t.integer "broken_count", default: 0, null: false
    t.binary "broken_pieces", null: false
    t.json "collapsed", default: {}, null: false
    t.integer "match_id", null: false
    t.json "partial", default: {}, null: false
    t.datetime "updated_at", null: false
    t.integer "world_object_id", null: false
    t.index ["match_id", "world_object_id"], name: "index_object_damages_on_match_id_and_world_object_id", unique: true
    t.index ["match_id"], name: "index_object_damages_on_match_id"
    t.index ["world_object_id"], name: "index_object_damages_on_world_object_id"
  end

  create_table "terrain_tiles", force: :cascade do |t|
    t.integer "base_cm", null: false
    t.datetime "created_at", null: false
    t.binary "heights", null: false
    t.integer "max_cm", null: false
    t.integer "min_cm", null: false
    t.integer "tx", null: false
    t.integer "tz", null: false
    t.datetime "updated_at", null: false
    t.integer "world_id", null: false
    t.index ["world_id", "tx", "tz"], name: "index_terrain_tiles_on_world_id_and_tx_and_tz", unique: true
    t.index ["world_id"], name: "index_terrain_tiles_on_world_id"
  end

  create_table "world_objects", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "cx", null: false
    t.integer "cz", null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.integer "piece_count", default: 0, null: false
    t.float "radius", null: false
    t.json "recipe", null: false
    t.integer "storey_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "world_id", null: false
    t.float "x", null: false
    t.float "y", null: false
    t.float "yaw", default: 0.0, null: false
    t.float "z", null: false
    t.index ["world_id", "cx", "cz"], name: "index_world_objects_on_world_id_and_cx_and_cz"
    t.index ["world_id", "name"], name: "index_world_objects_on_world_id_and_name", unique: true
    t.index ["world_id"], name: "index_world_objects_on_world_id"
  end

  create_table "worlds", force: :cascade do |t|
    t.json "bounds", null: false
    t.integer "chunk_size", default: 125, null: false
    t.string "content_digest", null: false
    t.datetime "created_at", null: false
    t.float "gravity", default: -9.81, null: false
    t.integer "height_step", default: 5, null: false
    t.string "name", null: false
    t.float "origin_x", default: 0.0, null: false
    t.float "origin_y", default: 0.0, null: false
    t.float "origin_z", default: 0.0, null: false
    t.integer "seed", default: 0, null: false
    t.string "slug", null: false
    t.json "spawns", null: false
    t.integer "srid"
    t.integer "tile_size", default: 500, null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_worlds_on_slug", unique: true
  end

  add_foreign_key "matches", "worlds"
  add_foreign_key "object_damages", "matches"
  add_foreign_key "object_damages", "world_objects"
  add_foreign_key "terrain_tiles", "worlds"
  add_foreign_key "world_objects", "worlds"
end

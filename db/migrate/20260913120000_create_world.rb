class CreateWorld < ActiveRecord::Migration[8.1]
  def change
    # A world is a coordinate frame plus the grids laid over it. srid and origin_* are
    # what make importing real survey data a subtraction and nothing else: a synthetic
    # world stores no srid and a zero origin, an RD import stores 28992 and the
    # Rijksdriehoek origin, and the same code reads both.
    create_table :worlds do |t|
      t.string  :slug, null: false
      t.string  :name, null: false

      t.integer :srid
      t.float   :origin_x, null: false, default: 0.0
      t.float   :origin_y, null: false, default: 0.0
      t.float   :origin_z, null: false, default: 0.0

      t.integer :tile_size, null: false, default: 500
      t.integer :height_step, null: false, default: 5
      t.integer :chunk_size, null: false, default: 125

      t.float   :gravity, null: false, default: -9.81
      t.integer :seed, null: false, default: 0

      t.json    :bounds, null: false
      t.json    :spawns, null: false

      # Digests everything under this world. It stamps the chunk URLs, so re-seeding
      # publishes under a new prefix and every cached payload invalidates itself.
      t.string  :content_digest, null: false

      t.timestamps
    end
    # The only lookup, and the actual invariant. Two rows; nothing else earns an index.
    add_index :worlds, :slug, unique: true

    # Heights as int16 centimetres relative to a per-tile base, little-endian, rows
    # north to south. Half the size of Float32 for precision 500x finer than the sample
    # spacing can express, and the per-tile base keeps absolute elevation out of the
    # range for good. Rows run north to south to match the survey data this will one day
    # be filled from, so an importer is a memcpy after the subtraction.
    create_table :terrain_tiles do |t|
      t.references :world, null: false, foreign_key: true
      t.integer :tx, null: false
      t.integer :tz, null: false

      t.integer :base_cm, null: false
      t.binary  :heights, null: false

      # Denormalised so culling and level-of-detail never decode the blob.
      t.integer :min_cm, null: false
      t.integer :max_cm, null: false

      t.timestamps
    end
    # Both access patterns are point lookups on this composite, and its leftmost prefix
    # covers world_id on its own. Unique because a duplicate tile would silently double
    # the terrain rather than fail.
    add_index :terrain_tiles, [ :world_id, :tx, :tz ], unique: true

    # What stands in the world. A building stores the recipe it is generated from, never
    # its pieces: a thousand buildings is a hundred and sixty thousand pieces, which is a
    # number of rows nothing here wants.
    create_table :world_objects do |t|
      t.references :world, null: false, foreign_key: true

      # The chunk containing the anchor owns the object outright. Duplicating a row into
      # every chunk it overlaps would split its damage across rows, so instead `radius`
      # says how far it reaches and is validated against the chunk size.
      t.integer :cx, null: false
      t.integer :cz, null: false

      t.string  :kind, null: false
      t.string  :name, null: false

      t.float   :x, null: false
      t.float   :y, null: false
      t.float   :z, null: false
      t.float   :yaw, null: false, default: 0.0
      t.float   :radius, null: false

      # Filled by the generator at seed time. This is the server's bounds check on a
      # reported piece index -- without it a malformed index corrupts the next object's
      # bitset rather than being rejected.
      t.integer :piece_count, null: false, default: 0
      t.integer :storey_count, null: false, default: 0

      t.json    :recipe, null: false

      t.timestamps
    end
    # The chunk endpoint runs this for every chunk in the resident ring, so without it a
    # page load is dozens of full scans.
    add_index :world_objects, [ :world_id, :cx, :cz ]
    # Makes the seeder idempotent by upsert, and makes "the building called X" findable
    # from a test. A duplicate name would be two objects sharing one handle and silently
    # splitting their damage.
    add_index :world_objects, [ :world_id, :name ], unique: true

    create_table :matches do |t|
      t.references :world, null: false, foreign_key: true
      t.string   :key, null: false

      # Destruction is authoritative in exactly one process. The claim always succeeds in
      # a single-process deployment, which is the point: an enforcement path that is never
      # exercised is one that does not work when it finally has to.
      t.string   :authority
      t.datetime :authority_claimed_at

      t.datetime :started_at, null: false
      t.datetime :last_active_at, null: false

      t.timestamps
    end
    add_index :matches, :key, unique: true
    # For the reaper. Cheap insurance on a table that only ever grows.
    add_index :matches, :last_active_at

    # Rows exist only for objects something has actually hit. A match where nobody breaks
    # anything has none; a match that levels the whole city has about a hundred kilobytes.
    create_table :object_damages do |t|
      t.references :match, null: false, foreign_key: true
      t.references :world_object, null: false, foreign_key: true

      # One bit per piece, least significant bit first.
      t.binary  :destroyed, null: false
      # Only the pieces that are damaged but still standing. Sparse because in practice a
      # touched building has a handful of those and a lot of intact-or-gone ones.
      t.json    :partial, null: false, default: {}

      # The lowest storey that has come down. Monotone: never raised, only lowered.
      t.integer :collapsed_from

      t.integer :destroyed_count, null: false, default: 0

      t.datetime :updated_at, null: false
    end
    # Serves the resync on its leftmost prefix and the flush as a point lookup. Unique is
    # load-bearing: it is what makes the upsert an upsert.
    add_index :object_damages, [ :match_id, :world_object_id ], unique: true
  end
end

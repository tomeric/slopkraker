module Game
  module Import
    # An imported world as the three fixture files it is defined by.
    #
    # Imported worlds land in test/fixtures beside the hand-made ones for the reason
    # db/seeds.rb gives: a world defined twice is a test passing against one world while
    # the browser shows another. So the importer's output is not a migration, not a seed
    # script and not a dump -- it is exactly the kind of file worlds.yml already is, and
    # everything that reads the hand-made worlds reads this one without being told.
    #
    # Written a line at a time rather than as one YAML.dump of everything, so the files can
    # be read and diffed: one entry per row, each opening with the attribution that says
    # where its numbers came from and which command to run to get them again.
    class Fixtures
      WRAP = 92

      def initialize(slug:, name:, frame:, origin_z:, bounds:, spawns:, roads:, objects:, tiles:, attribution:)
        @slug, @name, @frame, @origin_z = slug, name, frame, origin_z
        @bounds, @spawns, @roads, @objects, @tiles, @attribution = bounds, spawns, roads, objects, tiles, attribution
      end

      def world_yaml
        header("The world itself: the survey frame its coordinates are measured in, the grids laid over it, " \
               "the edges nothing travels past, where a car starts, and the roads drawn on the ground.") +
          entry(@slug,
                "slug" => @slug, "name" => @name, "bounds" => @bounds, "spawns" => @spawns,
                "content_digest" => content_digest, "srid" => @frame.srid,
                "origin_x" => @frame.origin_x, "origin_y" => @frame.origin_y, "origin_z" => @origin_z,
                "tile_size" => @frame.tile_size, "height_step" => @frame.height_step, "chunk_size" => @frame.chunk_size,
                "roads" => @roads)
      end

      def objects_yaml
        header("One row per building, each a recipe of a few hundred bytes that the generator expands into " \
               "surfaces on demand. piece_count is what the generator produced when this file was written: a row " \
               "holding a stale count refuses every index past it, so it is regenerated here rather than edited.") +
          generated.map { |object, set| entry(label_for(object), object_row(object, set)) }.join
      end

      def tiles_yaml
        header("The ground, as int16 centimetres above the world's origin_z, rows north to south and columns " \
               "west to east. Checked in as bytes because they are a survey rather than a function: there is no " \
               "formula to regenerate them from, only the DEM the import read.") +
          @tiles.map { |tile| tile_entry(tile) }.join
      end

      private
        # Generated once: the objects' piece counts, the world's digest and any count a
        # caller asks for all come from the same expansion.
        def generated
          @generated ||= @objects.map { |object| [ object, Building::Generator.call(object[:recipe]) ] }
        end

        # What the client is holding indices from. Twelve hex characters over the object
        # rows as written, piece counts included, so it moves whenever a recipe or the
        # generator does and a client on the old numbering is detectable rather than
        # silently addressing someone else's walls.
        def content_digest
          Digest::SHA256.hexdigest(JSON.generate(generated.map { |object, set| object_row(object, set) }))[0, 12]
        end

        def label_for(object) = "#{@slug}_#{object.fetch(:name).tr('-', '_')}"

        def object_row(object, set)
          x, z = object.fetch(:x), object.fetch(:z)
          cx, cz = @frame.chunk_of(x, z)
          {
            "world" => @slug, "kind" => "building", "name" => object.fetch(:name),
            "cx" => cx, "cz" => cz,
            "x" => x, "y" => object.fetch(:y), "z" => z,
            # The client never reads this -- a row's yaw is baked into its surfaces by the
            # generator. It is written because it is the bearing the import measured, and a
            # row whose surfaces look wrong is read against this rather than reverse
            # engineered from them.
            "yaw" => object.fetch(:yaw), "radius" => object.fetch(:radius),
            "piece_count" => set.piece_count, "storey_count" => set.storey_count,
            "recipe" => object.fetch(:recipe)
          }
        end

        def tile_entry(tile)
          body = { "world" => @slug, "tx" => tile.tx, "tz" => tile.tz,
                   "base_cm" => tile.base_cm, "min_cm" => tile.min_cm, "max_cm" => tile.max_cm }
          # Appended by hand: !!binary is what hands Active Record a binary string, and
          # Psych's own tag for one is neither that spelling nor on one line.
          dump("#{@slug}_tile_#{tile.tx}_#{tile.tz}", body) +
            "  heights: !!binary #{Base64.strict_encode64(tile.heights)}\n\n"
        end

        def entry(label, body) = "#{dump(label, body)}\n"

        def dump(label, body)
          visitor = Psych::Visitors::YAMLTree.create
          visitor << { label => body }
          flow(visitor.tree)
          visitor.tree.yaml(nil, line_width: -1).delete_prefix("---\n")
        end

        # A point is a pair, not two facts. Psych's default puts every number of every ring
        # on its own line, which turns a footprint into four hundred lines of column and the
        # roads into fifty kilobytes of it -- unreadable, undiffable, and the opposite of why
        # these are written a row at a time. So a sequence of nothing but scalars is emitted
        # inline, exactly as the hand-made fixtures beside these write their bounds; a
        # sequence of mappings -- spawns, roads, dwellings, boxes -- stays a block, because
        # that is the one that reads as a list.
        def flow(node)
          node.children&.each { |child| flow(child) }
          return unless node.is_a?(Psych::Nodes::Sequence) && node.children.all?(Psych::Nodes::Scalar)

          node.style = Psych::Nodes::Sequence::FLOW
        end

        def header(note)
          (wrap(note) + [ "" ] + wrap(@attribution)).map { |line| line.empty? ? "#" : "# #{line}" }.join("\n") + "\n\n"
        end

        def wrap(text)
          text.split(/\s+/).each_with_object([ "" ]) do |word, lines|
            if lines.last.empty? then lines[-1] = word
            elsif lines.last.length + 1 + word.length <= WRAP then lines[-1] = "#{lines.last} #{word}"
            else lines << word
            end
          end
        end
    end
  end
end

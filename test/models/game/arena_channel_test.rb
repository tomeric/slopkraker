require "test_helper"

class ArenaChannelTest < ActionCable::Channel::TestCase
  tests ArenaChannel

  setup { stub_connection(player_id: "player-1") }
  teardown { Game::Damage::Registry.reset! }

  def house
    World.find_by!(slug: "targets").world_objects.find_by!(kind: "building")
  end

  test "streams from the requested match" do
    subscribe(match: "night-shift")

    assert subscription.confirmed?
    assert_has_stream "arena:night-shift"
  end

  test "falls back to the lobby without a match" do
    subscribe
    assert_has_stream "arena:lobby"
  end

  test "refuses a match name that could forge a stream" do
    subscribe(match: "../admin secrets")
    assert_has_stream "arena:lobby"
  end

  test "stamps the player id rather than trusting the payload" do
    subscribe(match: "lobby")

    broadcast = capture_broadcast("arena:lobby") do
      perform :snapshot, "player_id" => "somebody-else", "vehicle" => "buggy",
                         "t" => 42, "p" => [ 1, 2, 3 ], "q" => [ 0, 0, 0, 1 ],
                         "v" => [ 0, 0, 0 ], "w" => [], "f" => 0
    end

    assert_equal "player-1", broadcast["player_id"]
    assert_equal "buggy", broadcast["vehicle"]
    assert_equal [ 1, 2, 3 ], broadcast["p"]
  end

  test "announces joining and leaving" do
    join = capture_broadcast("arena:lobby") { subscribe(match: "lobby") }
    assert_equal "join", join["type"]
    assert_equal "player-1", join["player_id"]

    subscribe(match: "lobby")
    leave = capture_broadcast("arena:lobby") { unsubscribe }
    assert_equal "leave", leave["type"]
  end

  private
    def capture_broadcast(stream)
      messages_before = broadcasts(stream).size
      yield
      new_messages = broadcasts(stream)[messages_before..] || []
      assert_not_empty new_messages, "expected a broadcast on #{stream}"
      JSON.parse(new_messages.last)
    end

  test "damage comes back as breaks" do
    target = house
    subscribe(match: "damage-test", world: "targets")

    broadcast = capture_broadcast("arena:damage-test") do
      perform :damage, "seq" => 1, "hits" => [ [ target.id, 0, 500.0, "impact" ] ]
    end

    assert_equal "breaks", broadcast["type"]
    assert_equal [ [ target.id, 0 ] ], broadcast["broken"]
  end

  # The sender has to receive this one. NetConnection drops anything stamped with its own
  # player_id, and the client that knocked the walls out is exactly the one that most needs
  # to hear the house came down.
  test "breaks are not stamped with the sender" do
    target = house
    subscribe(match: "damage-stamp", world: "targets")

    broadcast = capture_broadcast("arena:damage-stamp") do
      perform :damage, "seq" => 1, "hits" => [ [ target.id, 0, 500.0, "impact" ] ]
    end

    assert_nil broadcast["player_id"]
    assert broadcast["authority"].present?, "every breaks message says who decided it"
  end

  test "taking out two walls broadcasts the collapse" do
    target = house
    set = target.surface_set
    hits = set.for_storey(0).select { |s| s.kind == :wall }.first(2).flat_map do |surface|
      (surface.piece_offset...(surface.piece_offset + surface.piece_count)).map do |index|
        [ target.id, index, 500.0, "impact" ]
      end
    end
    subscribe(match: "collapse-test", world: "targets")

    broadcast = capture_broadcast("arena:collapse-test") do
      perform :damage, "seq" => 1, "hits" => hits
    end

    assert_equal [ [ target.id, 0 ] ], broadcast["collapses"]
  end

  test "a batch that changes nothing broadcasts nothing" do
    subscribe(match: "damage-quiet", world: "targets")

    assert_no_broadcasts("arena:damage-quiet") do
      perform :damage, "seq" => 1, "hits" => []
    end
  end

  test "damage without a world is refused" do
    subscribe(match: "damage-worldless")

    assert_no_broadcasts("arena:damage-worldless") do
      perform :damage, "seq" => 1, "hits" => [ [ 1, 0, 500.0, "impact" ] ]
    end
  end

  test "request_state answers the asker alone" do
    target = house
    subscribe(match: "state-test", world: "targets")
    perform :damage, "seq" => 1, "hits" => [ [ target.id, 0, 500.0, "impact" ] ]

    perform :request_state, "ids" => [ target.id ]

    reply = transmissions.last
    assert_equal "state", reply["type"]
    assert_equal 1, reply["objects"].first["broken_count"]
  end

  # Destruction is authoritative in one process. A process that loses the claim has to say
  # so rather than quietly applying damage nobody else will ever see.
  test "a process that does not hold the match refuses damage" do
    target = house
    world = World.find_by!(slug: "targets")
    Match.start(key: "taken", world: world).update!(
      authority: "somebody-else", authority_claimed_at: Time.current
    )
    subscribe(match: "taken", world: "targets")

    assert_no_broadcasts("arena:taken") do
      perform :damage, "seq" => 1, "hits" => [ [ target.id, 0, 500.0, "impact" ] ]
    end
    assert_equal "not_authoritative", transmissions.last["reason"]
  end
end

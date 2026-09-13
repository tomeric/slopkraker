require "test_helper"

class ArenaChannelTest < ActionCable::Channel::TestCase
  tests ArenaChannel

  setup { stub_connection(player_id: "player-1") }

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
end

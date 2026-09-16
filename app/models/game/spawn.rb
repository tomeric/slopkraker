module Game
  # Where a player starts, and which way they are pointed. Yaw matters: a spawn facing a
  # wall is a spawn nobody can drive out of.
  #
  # In its own file, where the autoloader expects Game::Spawn to be. It used to sit beside
  # Scene in scene.rb, which worked only because every caller happened to name Game::Scene
  # first -- World#spawn_points called on its own could not find it.
  Spawn = Struct.new(:position, :yaw, keyword_init: true) do
    def to_spec
      { position: position.to_a, yaw: yaw.to_f }
    end
  end
end

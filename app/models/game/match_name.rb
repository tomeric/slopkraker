module Game
  # A name for a new match: two words and a tag, like "copper-otter-4f21".
  #
  # Readable on purpose. A match name is the whole of how you invite somebody -- you send
  # them the link, or you read it down the phone -- so a UUID would technically do the job
  # and socially would not.
  #
  # The tag is what keeps it honest. Words alone would collide often enough to matter, and
  # a collision is not a cosmetic problem: it drops two strangers into each other's world
  # and hands one of them the other's wreckage, which is exactly the confusion the new
  # match button exists to end.
  module MatchName
    ADJECTIVES = %w[
      copper brass rusty crooked stubborn cheerful reckless quiet sudden idle
      crimson amber velvet hollow restless gentle rowdy nimble battered shiny
    ].freeze

    NOUNS = %w[
      otter badger heron magpie ferret walrus gibbon beetle lantern anvil
      turnip chimney kettle gherkin pylon bollard wheelbarrow accordion tuba clog
    ].freeze

    def self.generate
      "#{ADJECTIVES.sample}-#{NOUNS.sample}-#{SecureRandom.hex(2)}"
    end
  end
end

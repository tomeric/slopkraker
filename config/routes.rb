Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Geometry is immutable and travels over HTTP; damage is mutable and travels over the
  # socket. The digest in the path is what makes the first half true: a URL is cached for a
  # year as immutable, so a change to the bytes has to change the URL, and the digest IS
  # the bytes. Negative tile coordinates are real -- the hills world's four tiles meet at
  # the origin -- so the segments are constrained to allow the sign.
  scope "worlds/:slug/:digest", constraints: { digest: /[0-9a-f]{12}/ } do
    get "tiles/:tx/:tz", to: "terrain_tiles#show", as: :world_tile,
        constraints: { tx: /-?\d+/, tz: /-?\d+/ }
  end

  root "arenas#show"
end

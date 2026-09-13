# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "@rails/actioncable", to: "actioncable.esm.js"

# Vendored, committed. See docs in the plan: three is held at 0.170.0 because 0.178.0+
# splits the ESM build into three.module.js + three.core.js, whose relative import
# cannot survive Propshaft's production digesting.
pin "three", to: "three.js", preload: false # @0.170.0
pin "@dimforge/rapier3d-compat", to: "rapier3d_compat.js", preload: false # @0.20.0

# Vendored by hand rather than pinned through JSPM, because JSPM rewrites the bare "three"
# import to its own CDN URL -- which would load a second copy of three alongside the one
# above. This build's only import is bare "three", so the pin above resolves it to ours.
pin "@dgreenheck/three-pinata", to: "three_pinata.js", preload: false # @2.0.1

pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/game", under: "game"

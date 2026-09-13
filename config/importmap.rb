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

pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/game", under: "game"

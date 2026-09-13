import * as THREE from "three"
import { loadRapier } from "game/rapier"
import { createRenderer, createScene, createCamera, disposeScene } from "game/render/scene"
import { buildArenaView } from "game/render/arena_view"
import { createPhysicsWorld } from "game/physics/world"
import { buildVehicle, vehicleKeys } from "game/vehicles"
import { VehicleView } from "game/render/vehicle_view"
import { ChaseCamera } from "game/render/chase_camera"
import { InputManager } from "game/input/input_manager"
import { Hud } from "game/hud"
import { Projectiles } from "game/projectiles"
import { Destruction } from "game/destruction"
import { resolveDamage, explosionRadius, explosionForce } from "game/damage"
import { Explosions } from "game/explosions"
import { VehicleAudio } from "game/audio/vehicle_audio"
import { ControlsOverlay } from "game/controls_overlay"
import { DebugGizmos } from "game/render/debug_gizmos"
import { DamageGizmos } from "game/render/damage_gizmos"
import { HitMarkers } from "game/render/hit_markers"
import { Interpolator, createEntry, savePrevious, readBack } from "game/sim/interpolator"
import { BlastWave } from "game/blast_wave"
import { Telemetry } from "game/telemetry"

const MAX_FRAME_TIME = 0.25

// Fixed-step simulation with render interpolation. Physics runs at the rate Ruby
// specifies regardless of display refresh; meshes are interpolated between the last two
// physics states so a 60Hz display still looks smooth at 120Hz physics.
export class GameEngine {
  constructor({ canvas, root, spec, vehicleKey, playerId, match, onStatus, onMuteChange }) {
    this.canvas = canvas
    this.root = root || canvas.parentElement
    this.spec = spec
    this.playerId = playerId
    this.match = match
    this.vehicleKey = vehicleKey || "monster_truck"
    this.onStatus = onStatus || (() => {})
    this.onMuteChange = onMuteChange || (() => {})
    this.running = false
    this.rafId = null
    this.accumulator = 0
    this.lastFrame = 0
    this.interpolator = new Interpolator()
    this.pendingImpacts = []
    this.fallSpeed = 0
    this.impactSpeed = 0
    this.muted = false
    this.telemetry = new Telemetry()
    // The engine writes the counters it owns straight onto the readout.
    this.stats = this.telemetry.stats
  }

  async start() {
    this.onStatus("Loading physics…")
    const RAPIER = await loadRapier()
    if (this.disposed) return
    this.RAPIER = RAPIER

    this.fixedDt = 1 / this.spec.rules.physics_hz
    this.maxSubsteps = this.spec.rules.max_substeps

    this.renderer = createRenderer(this.canvas)
    const { scene, sun } = createScene()
    this.scene = scene
    this.sun = sun
    this.camera = createCamera(this.aspect())
    this.resize()

    const { world, colliders, props } = createPhysicsWorld(RAPIER, this.spec)
    this.world = world
    this.colliderIndex = colliders
    this.props = props

    this.arenaGroup = buildArenaView(this.scene, this.spec.arena)
    this.trackProps()

    this.eventQueue = new RAPIER.EventQueue(true)
    this.hitMarkers = new HitMarkers(this.scene, this.spec.rules.damage_flash)

    this.projectiles = new Projectiles({
      RAPIER, world, scene: this.scene, colliderIndex: this.colliderIndex,
      onDetonate: (at, spec, damage) => this.explode(at, spec, damage),
      onIgnite: (rocket) => {
        this.audio?.rocketIgnited()
        // Held until the rocket dies; projectiles.js stops it on detonation.
        rocket.thrustVoice = this.audio?.rocketThrust()
      }
    })
    this.explosions = new Explosions({
      scene: this.scene,
      onWave: (explosion) => this.blast.apply(explosion, this.vehicle)
    })
    this.destruction = new Destruction({
      RAPIER, world, scene: this.scene, colliderIndex: this.colliderIndex,
      onBreak: (prop) => {
        this.stats.broken += 1
        // Its rigid body is about to be freed; leaving the entry in the interpolation
        // list means the next readBack() calls translation() on freed wasm memory, which
        // traps and poisons the whole Rapier instance.
        this.interpolator.untrack(prop.body)
      }
    })
    this.blast = new BlastWave({
      props: this.props,
      destruction: this.destruction,
      projectiles: this.projectiles
    })

    this.hud = new Hud(this.root)
    this.gizmos = new DebugGizmos(this.scene)
    this.controls = new ControlsOverlay(
      this.root.querySelector('[data-arena-target="controls"]') || this.root,
      this.spec.input,
      { actionLabel: this.spec.vehicles[this.vehicleKey].action_label }
    )
    this.spawnVehicle(this.vehicleKey)

    this.input = new InputManager(this.canvas, this.spec.input, this.vehicle.spec.camera)

    this.onResize = () => this.resize()
    window.addEventListener("resize", this.onResize)

    this.stats.bodies = this.interpolator.size
    this.stats.ready = true
    window.__arena = this.stats
    window.__arenaDebugVisible = this.gizmos.visible
    window.__arenaMasterGain = () => this.audio?.engine?.master?.gain?.value ?? null
    // Same reasoning as the gain hook: the blast curves are a port of the Ruby model and
    // the parity test has to be able to reach them.
    window.__explosionRadius = explosionRadius
    window.__explosionForce = explosionForce

    this.running = true
    this.lastFrame = performance.now()
    this.rafId = requestAnimationFrame(this.frame)
    this.onStatus(null)
    this.onMuteChange(this.muted)
  }

  toggleMute() {
    this.muted = this.audio ? this.audio.toggleMute() : !this.muted
    this.stats.muted = this.muted
    this.onMuteChange(this.muted)
    return this.muted
  }

  spawnVehicle(key) {
    this.teardownVehicle()

    const spec = this.spec.vehicles[key]
    const spawn = this.spec.arena.spawns[0]

    this.vehicleKey = key
    this.vehicle = buildVehicle(key, {
      RAPIER: this.RAPIER,
      world: this.world,
      spec,
      spawn,
      colliderIndex: this.colliderIndex,
      projectiles: this.projectiles,
      meta: {
        key,
        owner: "local",
        impactThreshold: this.spec.rules.impact_force_threshold
      }
    })

    this.vehicleView = new VehicleView(this.scene, spec)
    this.audio?.dispose()
    this.audio = new VehicleAudio(this.canvas, spec)
    // A vehicle swap rebuilds the audio graph, so re-apply the preference.
    // First build adopts the stored preference; later ones inherit the session's.
    this.muted = this.audio.engine.muted || this.muted
    this.audio.engine.setMuted(this.muted)
    this.stats.muted = this.muted
    this.onMuteChange(this.muted)

    // Parented to the vehicle's own group so the boxes ride with the car.
    this.damageGizmos = new DamageGizmos(this.vehicleView.group, spec, this.spec.rules.damage)
    this.damageGizmos.visible = this.gizmos ? this.gizmos.visible : true
    this.controls?.setActionLabel(spec.action_label)
    this.lastRocketCount = this.projectiles.fired
    this.chaseCamera = new ChaseCamera(this.camera, {
      ...spec.camera,
      turbo_fov_kick: spec.turbo.fov_kick
    })

    // The vehicle interpolates like anything else but renders through a VehicleView and
    // keeps its own interpolated transform, so it gets the shared entry plus those two
    // rather than joining the Interpolator's list.
    const position = new THREE.Vector3(spawn.position[0], spawn.position[1], spawn.position[2])
    this.vehicleEntity = {
      ...createEntry({
        body: this.vehicle.body,
        position,
        quaternion: new THREE.Quaternion()
      }),
      view: this.vehicleView,
      renderPos: position.clone(),
      renderRot: new THREE.Quaternion()
    }
  }

  teardownVehicle() {
    if (!this.vehicle) return
    this.damageGizmos?.dispose()
    this.damageGizmos = null
    this.world.removeVehicleController(this.vehicle.controller)
    this.world.removeRigidBody(this.vehicle.body)
    this.vehicleView?.dispose()
    this.vehicle = null
    this.vehicleView = null
    this.vehicleEntity = null
  }

  // Props are the only arena objects that move, so they are the only ones needing
  // interpolation state.
  trackProps() {
    for (const prop of this.props) {
      const mesh = this.arenaGroup.getObjectByName(prop.spec.name)
      if (!mesh) continue
      prop.mesh = mesh
      this.interpolator.track({ body: prop.body, mesh })
    }
  }

  frame = (now) => {
    if (!this.running) return
    this.rafId = requestAnimationFrame(this.frame)

    let frameTime = (now - this.lastFrame) / 1000
    this.lastFrame = now
    // A backgrounded tab or a debugger pause hands back an enormous delta; without this
    // clamp the accumulator would try to catch up over hundreds of substeps.
    if (frameTime > MAX_FRAME_TIME) frameTime = MAX_FRAME_TIME
    this.accumulator += frameTime

    // Sampled once per frame so every substep in this frame sees identical input.
    const input = this.input.sample()

    if (input.respawn) this.controls.flash("respawn")
    if (input.cameraRecentre) this.controls.flash("camera_recentre")
    if (input.switchVehicle) this.controls.flash("switch_vehicle")
    if (input.toggleControls) this.controls.flash("toggle_controls")
    if (input.toggleMute) {
      this.controls.flash("toggle_mute")
      this.toggleMute()
    }
    if (input.toggleDebug) {
      this.controls.flash("toggle_debug")
      this.gizmos.toggle()
      if (this.damageGizmos) this.damageGizmos.visible = this.gizmos.visible
      this.projectiles.debugVisible = this.gizmos.visible
      this.explosions.debugVisible = this.gizmos.visible
      window.__arenaDebugVisible = this.gizmos.visible
    window.__arenaMasterGain = () => this.audio?.engine?.master?.gain?.value ?? null
    }

    if (input.switchVehicle) {
      const keys = vehicleKeys(this.spec)
      const next = keys[(keys.indexOf(this.vehicleKey) + 1) % keys.length]
      this.spawnVehicle(next)
      this.input.pointer.sensitivity = this.vehicle.spec.camera.orbit_sensitivity
    }
    if (input.respawn) this.vehicle.respawn()

    // Debug/test hook: park the vehicle at a known pose.
    if (window.__arenaPlace) {
      const place = window.__arenaPlace
      window.__arenaPlace = null
      this.vehicle.placeAt(place)
    }

    // Debug/test hook: drop the vehicle in upside down to exercise flip recovery.
    if (window.__arenaFlip) {
      window.__arenaFlip = false
      this.vehicle.invert()
    }

    let substeps = 0
    while (this.accumulator >= this.fixedDt && substeps < this.maxSubsteps) {
      this.step(this.fixedDt, input)
      this.accumulator -= this.fixedDt
      substeps += 1
    }
    // Bail out of the spiral of death rather than falling further behind each frame.
    if (substeps === this.maxSubsteps) this.accumulator = 0

    this.controls.update(frameTime, input, this.input.gamepad.connected)
    this.render(this.accumulator / this.fixedDt, frameTime, input)
    input.endFrame()
  }

  step(dt, input) {
    this.interpolator.beginStep()
    const vehicle = this.vehicleEntity
    if (vehicle) savePrevious(vehicle)

    this.vehicle.update(dt, input)

    // Captured BEFORE the solver runs. Contact events are reported after the step, by
    // which point the car and whatever it hit have already been pushed toward a shared
    // velocity -- so measuring the closing speed there reports a real impact as a nudge.
    // This is also the speed the debug overlay predicts from, so the two agree.
    const preStep = this.vehicle.body.linvel()
    this.impactSpeed = Math.hypot(preStep.x, preStep.y, preStep.z)

    this.world.step(this.eventQueue)
    this.stats.steps += 1
    this.handleContacts()
    this.projectiles.update(dt)
    this.explosions.update(dt)
    this.destruction.update(dt)
    this.hitMarkers.update(dt)

    this.interpolator.endStep()
    if (vehicle) {
      readBack(vehicle)
      if (this.vehicle.groundedWheels() === 0) {
        this.fallSpeed = Math.min(this.vehicle.body.linvel().y, this.fallSpeed ?? 0)
      } else if (this.fallSpeed) {
        this.pendingLanding = this.fallSpeed
        this.fallSpeed = 0
      }
    }
  }

  // Physical impacts are reported here and scored with the rules Ruby shipped in the
  // spec, so damage stays Ruby's to define while feedback stays immediate.
  //
  // Impacts are collected during the drain and applied afterwards: Rapier borrows the
  // world mutably for the duration of a drain callback, so creating or removing a body
  // inside one trips Rust's aliasing check ("recursive use of an object").
  handleContacts() {
    const pending = this.pendingImpacts
    pending.length = 0

    this.eventQueue.drainCollisionEvents((handle1, handle2, started) => {
      if (!started) return
      const a = this.colliderIndex.get(handle1)
      const b = this.colliderIndex.get(handle2)
      if (a?.kind === "rocket") this.projectiles.markDead(a.rocket)
      if (b?.kind === "rocket") this.projectiles.markDead(b.rocket)
    })

    const rules = this.spec.rules.damage
    const state = this.damageState()

    this.eventQueue.drainContactForceEvents((event) => {
      const a = this.colliderIndex.get(event.collider1())
      const b = this.colliderIndex.get(event.collider2())
      if (!a || !b) return

      const attacker = a.owner ? a : b.owner ? b : null
      if (!attacker) return
      const target = attacker === a ? b : a
      if (!target.prop || target.prop.broken) return

      const damage = resolveDamage({
        rules, part: attacker.part, speed: this.impactSpeed, state
      })
      if (damage > 0) {
        pending.push({
          prop: target.prop, damage, key: attacker.name,
          label: attacker.name.replace(/_/g, " ").toUpperCase()
        })
      }
    })

    for (const impact of pending) {
      // Read the position BEFORE applying damage: a fatal hit frees the prop's body, and
      // touching it afterwards reaches into released wasm memory.
      const at = impact.prop.body.translation()
      const where = new THREE.Vector3(at.x, at.y + 1.2, at.z)

      this.destruction.apply(impact.prop, impact.damage)
      this.stats.lastDamage = Math.round(impact.damage)
      this.audio?.impact(Math.min(impact.damage / 120, 1))

      // Highlight the part that connected, and float the damage where it landed.
      this.damageGizmos?.registerHit(impact.key, impact.damage)
      this.hitMarkers.add(where, impact.damage, impact.label)
    }
    pending.length = 0
  }

  // Everything a conditional part needs to decide whether its bonus applies. The vehicle
  // owns it: the bull bar's own collider reads the same answer to decide how far to swing
  // out, and the three must not be able to disagree.
  damageState() {
    return this.vehicle ? this.vehicle.damageState() : {}
  }

  // A rocket landing leaves an explosion behind rather than resolving in a single frame.
  // The object owns its own radius and lifetime; BlastWave is what it does to the world
  // as that radius grows.
  explode(at, spec, damage) {
    this.stats.explosions += 1
    this.hitMarkers?.add(at, damage)
    this.audio?.explosion(Math.min(damage / 160, 1))
    this.stats.lastExplosion = { x: +at.x.toFixed(1), y: +at.y.toFixed(1), z: +at.z.toFixed(1) }

    this.explosions.spawn({ at, spec: spec.explosion, damage })
  }

  render(alpha, frameTime, input) {
    this.interpolator.interpolate(alpha)

    const entity = this.vehicleEntity
    if (entity) {
      entity.renderPos.lerpVectors(entity.prevPos, entity.currPos, alpha)
      entity.renderRot.slerpQuaternions(entity.prevRot, entity.currRot, alpha)
      entity.view.setTransform(entity.renderPos, entity.renderRot)
      // Wheels are read live, never interpolated: suspension travel and steer angle are
      // exactly what the player reads as responsiveness.
      entity.view.syncWheels(this.vehicle.controller)
      // Same reasoning: the bar's reach is read live, never interpolated.
      entity.view.syncBullBar(this.vehicle.bullBarBox())
      // Flames ease on the wall clock, like the plume and the damage gizmos, not on the
      // fixed step -- they are decoration, and should not stutter when substeps do.
      entity.view.syncBoosters(this.vehicle.boosterState?.(), frameTime)
      this.gizmos.update(this.vehicle, entity.renderPos)
      this.damageGizmos?.update(frameTime, this.vehicle)
      this.projectiles.sync(frameTime)
      this.explosions.sync()
      this.destruction.sync()

      this.chaseCamera.update(
        frameTime, entity.renderPos, entity.renderRot,
        this.vehicle.speed, input, this.vehicle.turboActive,
        this.vehicle.drifting ? this.vehicle.driftDirection : 0
      )

      // Keep the shadow frustum centred on the action.
      this.sun.target.position.copy(entity.renderPos)
      this.sun.position.set(entity.renderPos.x + 48, entity.renderPos.y + 72, entity.renderPos.z + 36)
      this.sun.target.updateMatrixWorld()

      this.hud.update(frameTime, this.vehicle)

      this.telemetry.update({
        vehicle: this.vehicle,
        vehicleKey: this.vehicleKey,
        entity,
        camera: this.camera,
        projectiles: this.projectiles,
        explosions: this.explosions,
        destruction: this.destruction,
        hitMarkers: this.hitMarkers,
        damageGizmos: this.damageGizmos,
        audio: this.audio,
        input,
        fallSpeed: this.fallSpeed
      })
      // A rising fired count is the cleanest signal that a rocket left the rail.
      if (this.projectiles.fired > this.lastRocketCount) {
        this.lastRocketCount = this.projectiles.fired
        this.audio.rocketFired()
      }

      const stats = this.stats
      this.controls.muted = this.muted
      this.audio.update(frameTime, {
        speed: stats.speed, throttle: input.throttle, grounded: stats.grounded,
        turbo: stats.turboOn, jets: stats.jets, slip: stats.slip, fallSpeed: this.fallSpeed,
        drifting: stats.drifting
      })
    }

    this.renderer.render(this.scene, this.camera)
    this.telemetry.frame(frameTime)
  }

  aspect() {
    const { clientWidth, clientHeight } = this.canvas
    return clientWidth / Math.max(clientHeight, 1)
  }

  resize() {
    const width = this.canvas.clientWidth
    const height = this.canvas.clientHeight
    this.renderer.setSize(width, height, false)
    this.camera.aspect = this.aspect()
    this.camera.updateProjectionMatrix()
  }

  dispose() {
    this.disposed = true
    this.running = false
    if (this.rafId) cancelAnimationFrame(this.rafId)
    if (this.onResize) window.removeEventListener("resize", this.onResize)
    this.input?.dispose()

    // Rapier lives on the wasm heap and is not reachable by the JS garbage collector.
    this.audio?.dispose()
    this.controls?.dispose()
    this.gizmos?.dispose()
    this.damageGizmos?.dispose()
    this.hitMarkers?.dispose()
    this.projectiles?.dispose()
    this.destruction?.dispose()
    this.eventQueue?.free()
    this.world?.free()

    if (this.scene) disposeScene(this.scene)
    this.renderer?.dispose()
    this.renderer?.forceContextLoss()
    this.interpolator.clear()
    if (window.__arena === this.stats) delete window.__arena
  }
}


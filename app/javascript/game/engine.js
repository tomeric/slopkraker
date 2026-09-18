import * as THREE from "three"
import { loadRapier } from "game/rapier"
import { loadTerrain, renderHeightAt } from "game/world/terrain"
import { castTerrain } from "game/physics/terrain"
import { buildTerrainView } from "game/render/terrain_view"
import { installParityHooks } from "game/parity"
import { createRenderer, createScene, createCamera, disposeScene, qualityFor } from "game/render/scene"
import { buildArenaView } from "game/render/arena_view"
import { createPhysicsWorld } from "game/physics/world"
import { buildVehicle, vehicleKeys } from "game/vehicles"
import { VehicleView } from "game/render/vehicle_view"
import { ChaseCamera } from "game/render/chase_camera"
import { InputManager } from "game/input/input_manager"
import { Hud } from "game/hud"
import { Projectiles } from "game/projectiles"
import { Destruction } from "game/destruction"
import { resolveDamage, partKind, explosionRadius, explosionForce } from "game/damage"
import { Explosions } from "game/explosions"
import { VehicleAudio } from "game/audio/vehicle_audio"
import { ControlsOverlay } from "game/controls_overlay"
import { DebugGizmos } from "game/render/debug_gizmos"
import { BuildingLabels } from "game/render/building_labels"
import { DamageGizmos } from "game/render/damage_gizmos"
import { HitMarkers } from "game/render/hit_markers"
import { Interpolator, createEntry, savePrevious, readBack } from "game/sim/interpolator"
import { BlastWave } from "game/blast_wave"
import { SpatialGrid } from "game/sim/spatial_grid"
import { Buildings } from "game/world/buildings"
import { Telemetry } from "game/telemetry"
import { NetConnection } from "game/net/connection"
import { DamageReporter } from "game/net/damage_reporter"
import { encodeSnapshot } from "game/net/snapshot"
import { RemoteVehicle } from "game/net/remote_vehicle"

const MAX_FRAME_TIME = 0.25
const SCRATCH_AWAY = new THREE.Vector3()
// One car's box, for sweeping debris. Reused every step for every car rather than
// allocated at 120Hz.
const SWEEP = {
  position: new THREE.Vector3(), rotation: new THREE.Quaternion(), inverse: new THREE.Quaternion(),
  forward: new THREE.Vector3(), velocity: new THREE.Vector3(), halfX: 0, halfZ: 0, top: 0
}

// Fixed-step simulation with render interpolation. Physics runs at the rate Ruby
// specifies regardless of display refresh; meshes are interpolated between the last two
// physics states so a 60Hz display still looks smooth at 120Hz physics.
export class GameEngine {
  constructor({ canvas, root, spec, vehicleKey, playerId, match, world, quality, onStatus, onMuteChange }) {
    this.canvas = canvas
    this.root = root || canvas.parentElement
    this.spec = spec
    this.playerId = playerId
    this.match = match
    // Named slug, not `world`: this.world is the Rapier physics world, and the collision
    // would be silent -- physics would win, since it is assigned later.
    this.worldSlug = world
    this.vehicleKey = vehicleKey || "monster_truck"
    this.qualityName = quality || "high"
    this.quality = qualityFor(quality)
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
    // The direction that speed was in, kept alongside it and reused every step rather
    // than reallocated at 120Hz. This is what a car aims back down after going through
    // something, so the two are captured together and can never disagree.
    this.impactVelocity = { x: 0, y: 0, z: 0 }
    this.muted = false
    this.telemetry = new Telemetry()
    // The engine writes the counters it owns straight onto the readout.
    this.stats = this.telemetry.stats
  }

  async start() {
    this.onStatus("Loading physics…")
    // The wasm and the tiles both take a round trip, so they take it together. A tile
    // that fails to load rejects with its coordinates, which the controller shows.
    const [ RAPIER, terrain ] = await Promise.all([ loadRapier(), loadTerrain(this.spec.arena.terrain) ])
    if (this.disposed) return
    this.RAPIER = RAPIER
    this.terrain = terrain
    // "The ground here", for everything that lays something on it. Null on a flat world,
    // and everything that takes it reproduces its old behaviour exactly when it is null.
    this.ground = terrain ? (x, z) => terrain.heightAt(x, z) : null

    this.fixedDt = 1 / this.spec.rules.physics_hz
    this.maxSubsteps = this.spec.rules.max_substeps

    this.renderer = createRenderer(this.canvas, this.quality)
    const { scene, sun } = createScene(this.quality)
    this.scene = scene
    this.sun = sun
    this.camera = createCamera(this.aspect())
    this.resize()

    const { world, colliders, props } = createPhysicsWorld(RAPIER, this.spec, terrain)
    this.world = world
    this.colliderIndex = colliders
    this.props = props

    this.arenaGroup = buildArenaView(this.scene, this.spec.arena)
    if (terrain) this.terrainGroup = buildTerrainView(this.scene, terrain, this.spec.rules.terrain)
    this.propGrid = new SpatialGrid({ cellSize: 5 })
    this.trackProps()

    // Opened before the buildings, because every building reports through the reporter and
    // a break landing before it exists would be a break the server never hears about.
    this.connection = new NetConnection({
      match: this.match,
      world: this.worldSlug,
      playerId: this.playerId,
      onMessage: (data) => this.onNetMessage(data),
      onStatus: (up) => this.onNetStatus(up)
    })
    this.reporter = new DamageReporter({
      connection: this.connection, hz: this.spec.rules.snapshot_hz,
      maxHits: this.spec.rules.damage.max_hits_per_batch
    })
    this.collapsesSeen = 0
    // Reasons the server has refused something this session, batch truncation among them.
    // Never expected to gain an entry -- the client is meant to split its own batches to
    // the cap it was shipped -- so a system test asserts this stays empty rather than
    // merely that destruction still worked.
    this.netErrors = []
    // Other players' cars, keyed by the player_id the server stamps. Nothing is ever
    // created for ourselves: our own broadcasts are dropped in NetConnection.
    this.remotes = new Map()
    this.snapshotTick = 0
    this.sinceSnapshot = 0

    this.buildings = new Buildings({
      RAPIER, world, scene: this.scene, spec: this.spec,
      materials: this.spec.materials, colliderIndex: this.colliderIndex,
      grid: this.propGrid,
      ground: this.ground,
      onDamage: (id, piece, raw, kind) => this.reporter.report(id, piece, raw, kind)
    })

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
      minimumFraction: this.spec.rules.damage.minimum_fraction,
      onBreak: (prop) => {
        this.stats.broken += 1
        // Its rigid body is about to be freed; leaving the entry in the interpolation
        // list means the next readBack() calls translation() on freed wasm memory, which
        // traps and poisons the whole Rapier instance.
        this.interpolator.untrack(prop.body)
        this.propGrid.remove(prop)
      }
    })
    this.blast = new BlastWave({
      props: this.props,
      destruction: this.destruction,
      projectiles: this.projectiles,
      grid: this.propGrid,
      rules: this.spec.rules.damage,
      sweepDebris: (at, inner, outer) => this.buildings?.blastDebris(at, inner, outer)
    })

    this.hud = new Hud(this.root)
    this.gizmos = new DebugGizmos(this.scene)
    // Part of the same overlay: a plate above each nearby building saying what it is.
    this.buildingLabels = new BuildingLabels(this.scene, this.buildings?.list ?? [])
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

    // Destruction is testable without driving into anything. Aiming a car at a wall and
    // hoping is where most of this suite's flakiness comes from, and none of what is worth
    // asserting about a break needs a collision to have caused it.
    window.__arenaBreak = (piece, buildingId) => this.buildings?.find(buildingId)?.break(piece)
    window.__arenaRestore = (piece, buildingId) => this.buildings?.find(buildingId)?.restore(piece)
    window.__arenaDamagePiece = (piece, amount, buildingId) =>
      this.buildings?.find(buildingId)?.damage(piece, amount)
    window.__arenaPieceState = (piece, buildingId) => {
      const building = this.buildings?.find(buildingId)
      if (!building) return null
      return {
        material: building.material[piece],
        standing: building.standing(piece),
        health: building.health[piece],
        maxHealth: building.maxHealth[piece]
      }
    }
    // Which cells share a fate with this one. A hit takes the block, not the cell, so a
    // test asserting "one break removed one piece" would be asserting the old behaviour.
    window.__arenaPieceBlock = (piece, buildingId) =>
      this.buildings?.find(buildingId)?.block(piece) ?? []
    window.__arenaDraws = () => this.renderer.info.render.calls
    window.__arenaCollapses = () => this.collapsesSeen ?? 0
    // The reasons the server has refused this session, batch truncation among them. A test
    // driving a huge break in one frame asserts this stays empty -- if it is not, the
    // client failed to split its own batch to the cap it was shipped.
    window.__arenaNetErrors = () => this.netErrors.slice()
    window.__arenaDebrisSpawned = () => this.buildings?.debrisSpawned ?? 0
    // How many pieces of a condemned building are in the air right now. Zero at rest, so a
    // test can watch a collapse leave the ground and come back to it.
    window.__arenaFalling = () => this.buildings?.fallingCount ?? 0
    // Cells rather than bodies. The two together say how much of the house left the ground
    // and how coarsely it did it, which is the whole of what a collapse is judged on.
    window.__arenaFallingCells = () => this.buildings?.fallingCells ?? 0
    // Reserved, standing and cleared heaps. An intact house has only the first.
    window.__arenaRubble = () => this.buildings?.rubbleCounts ?? null
    // A piece's world transform, flattened. Exists so a test can prove two clients put a
    // piece in the SAME PLACE, which is the whole claim rubble makes and which comparing
    // piece indices alone would not catch -- identical indices in different positions
    // would look exactly like this working.
    window.__arenaPieceMatrix = (piece, buildingId) =>
      this.buildings?.find(buildingId)?.matrices[piece]?.toArray() ?? null
    // Which materials a heap's chunks are made of. "The wreckage is made of what the house
    // was made of" is an assertion about this, and two players seeing the same chunks is
    // an assertion about it agreeing across sessions.
    window.__arenaHeapFragments = (piece, buildingId) =>
      this.buildings?.find(buildingId)?.heapFragmentMaterials(piece) ?? []
    // Chunks left lying by cleared heaps. Positive the moment a heap clears, zero once
    // they have faded -- which is the whole of what clearing a heap is meant to look like.
    window.__arenaRemnants = () => this.buildings?.remnantCount ?? 0
    // Small debris kicked out of a car's or a blast's way, cumulatively, and how much of it
    // is still visible. The first says the sweep reached something; the second, once it
    // reads zero again, says kicked debris goes away.
    window.__arenaDebrisKicked = () => this.buildings?.debrisKicked ?? 0
    window.__arenaDebrisKickedLive = () => this.buildings?.debrisKickedLive ?? 0
    window.__arenaRemotes = () => this.remotes?.size ?? 0
    window.__arenaReported = () => this.reporter?.sent ?? 0
    window.__arenaBuildingIds = () => this.buildings?.list.map((b) => b.id) ?? []
    window.__arenaBuildingSpec = (id) => this.buildings?.find(id)?.spec ?? null
    // How many slabs THIS building put in the air on its own behalf, as against how many
    // are up there altogether. The two are the same number while one house exists, which
    // is exactly why the falling budget could be over-subscribed across a street without
    // anything looking wrong: a building that is told it may drop six hundred slabs will
    // report having dropped six hundred whether or not the world could still hold them.
    window.__arenaSlabsDropped = (id) => this.buildings?.find(id)?.expectedSlabs ?? 0
    // Per building, so "collapsing one house left its neighbour untouched" is one read
    // rather than a thousand round trips through __arenaPieceState.
    window.__arenaBuildingStanding = (id) => this.buildings?.find(id)?.standingCount ?? 0
    // What the overlay says about every building -- category, name, source ids -- and
    // whether its plate is showing, so a test can assert on the words rather than pixels.
    window.__arenaBuildingLabels = () => this.buildingLabels?.readout() ?? []
    // Where the car actually is. "It got off the pile" is a claim about height and nothing
    // else -- telemetry carries speeds, which read identically for a car that sank through
    // the wreckage and one still perched on top of it going nowhere.
    window.__arenaVehiclePos = () => {
      const at = this.vehicle.body.translation()
      return [ at.x, at.y, at.z ]
    }
    // How many times a car has been shaken loose. A counter rather than a flag, because
    // the assertion worth making is that it fired AT ALL on a stranded car and NEVER on a
    // car that is merely in the air.
    window.__arenaUnstuck = () => this.vehicle?.unstuck ?? 0
    // What is holding the car up when no wheel can reach anything -- null while driving.
    window.__arenaSupports = () => this.vehicle?.supports?.length ?? 0
    // The ground under a point as the client samples it -- the port of Tile.interpolate.
    // Null on a world without terrain.
    window.__arenaTerrainHeight = (x, z) => (this.terrain ? this.terrain.heightAt(x, z) : null)
    // The proof that the ground the wheels stand on is the ground that is drawn: a physics
    // ray against the heightfield versus the drawn triangles versus the sampler, plus what
    // the OTHER diagonal would have said, so a test can show it would have noticed.
    window.__arenaTerrainProbe = (x, z) => this.probeTerrain(x, z)
    // Where a heap was put down and on what ground. "The wreckage lies on the slope" is a
    // claim about this against __arenaTerrainHeight at the same point.
    window.__arenaHeapGround = (piece, buildingId) => this.buildings?.find(buildingId)?.heapGround(piece) ?? null
    // The JS side of every ported Ruby/JS pair, for parity_test.rb.
    installParityHooks({ spec: this.spec, buildings: this.buildings, terrain: this.terrain })
    window.__arenaQuality = this.qualityName

    this.running = true
    this.lastFrame = performance.now()
    this.rafId = requestAnimationFrame(this.frame)
    this.onStatus(null)
    this.onMuteChange(this.muted)
  }

  // Ours goes out at snapshot_hz, the same rate damage is batched at. Every client
  // simulates its own car and nobody simulates anybody else's, so this is the whole of
  // what other players ever learn about us.
  sendSnapshot(dt) {
    this.sinceSnapshot += dt
    const interval = 1 / this.spec.rules.snapshot_hz
    if (this.sinceSnapshot < interval) return
    this.sinceSnapshot = 0
    if (!this.vehicle) return

    this.connection?.sendSnapshot(
      encodeSnapshot(this.vehicle, this.vehicleKey, ++this.snapshotTick)
    )
  }

  // Silence is what counts as gone. A browser closing a tab does not reliably get to run
  // JavaScript on the way out, so the unsubscribe never reaches the server and it falls
  // back to noticing a dead socket -- measured at over twelve seconds, which is a long time
  // for an abandoned car to sit in the road. The `leave` message is still honoured when it
  // arrives; this is what catches every case where it does not.
  updateRemotes() {
    const now = performance.now() / 1000
    const timeout = this.spec.rules.remote_timeout

    for (const [ playerId, remote ] of this.remotes) {
      if (remote.lastSeen !== null && now - remote.lastSeen > timeout) {
        this.dropRemote(playerId)
        continue
      }
      remote.update(now)
    }
  }

  // Find or build the car belonging to another player.
  //
  // This creates a Rapier body, which looks like it breaks the rule in CLAUDE.md about
  // never creating one inside a step -- it does not. A socket message is delivered on the
  // event loop, and JavaScript is single threaded, so this can only run BETWEEN frames and
  // never part way through world.step(). Worth stating, because it reads wrong.
  remoteFor(playerId, vehicleKey) {
    const existing = this.remotes.get(playerId)
    if (existing) return existing

    const spec = this.spec.vehicles[vehicleKey] || this.spec.vehicles[this.vehicleKey]
    if (!spec || !this.world) return null

    const remote = new RemoteVehicle({
      RAPIER: this.RAPIER, world: this.world, scene: this.scene, spec,
      colliderIndex: this.colliderIndex, playerId,
      delay: this.spec.rules.interpolation_delay
    })
    this.remotes.set(playerId, remote)
    return remote
  }

  dropRemote(playerId) {
    const remote = this.remotes.get(playerId)
    if (!remote) return

    remote.dispose()
    this.remotes.delete(playerId)
  }

  // Everything the server decides about the world arrives here. All of it is monotone --
  // pieces only break, a collapse only ever moves downward -- so applying a message twice
  // costs nothing and a break this client already predicted is simply confirmed.
  onNetMessage(data) {
    switch (data.type) {
      case "breaks":
        if (!this.buildings) return
        this.buildings.applyBreaks(data.broken)
        for (const [ objectId, storey ] of data.collapses || []) {
          this.buildings.applyCollapse(objectId, storey)
          this.collapsesSeen++
        }
        break
      case "state":
        this.buildings?.applyState(data.objects)
        break
      case "snapshot":
        this.remoteFor(data.player_id, data.vehicle)?.push(data, performance.now() / 1000)
        break
      case "leave":
        this.dropRemote(data.player_id)
        break
      case "error":
        // Loud on purpose: the suite surfaces SEVERE console errors on a wait_for timeout,
        // so a process that has lost the match shows up as a named cause rather than as
        // destruction mysteriously doing nothing.
        console.error(`arena: server refused damage (${data.reason})`)
        this.netErrors.push(data.reason)
        break
    }
  }

  // Asked once per connect, not once per boot: a reconnect has to catch up on everything
  // that broke while the socket was down, and the answer is monotone so asking again is
  // always safe.
  onNetStatus(up) {
    // The socket is opened before the buildings are built, so a fast connect can land
    // here first. Nothing to resync against yet, and the next connect will ask again.
    if (!up || !this.buildings) return
    this.connection.requestState(this.buildings.list.map((building) => building.id))
  }

  toggleMute() {
    this.muted = this.audio ? this.audio.toggleMute() : !this.muted
    this.stats.muted = this.muted
    this.onMuteChange(this.muted)
    return this.muted
  }

  // Three answers to "how high is the ground here" that must agree, and a fourth that must
  // not: the physics ray, the drawn triangles, the sampler, and the opposite diagonal.
  probeTerrain(x, z) {
    if (!this.terrain || !this.terrain.tileAt(x, z)) return null

    const physics = castTerrain(this.RAPIER, this.world, this.colliderIndex, this.terrain, x, z)
    const render = renderHeightAt(this.terrain, x, z)
    const sampled = this.terrain.heightAt(x, z)
    const other = this.terrain.otherDiagonalAt(x, z)
    const delta = physics === null || render === null ? null : physics - render
    return { physics, render, sampled, other, delta }
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
      support: this.spec.rules.support,
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
      // Held onto so a blast can read where the prop is without asking wasm: the
      // interpolator has already read this body's transform once this step.
      prop.entry = this.interpolator.track({ body: prop.body, mesh })
      // Dynamic: props get knocked about, so the grid re-seats them as they move.
      this.propGrid.insert(prop, mesh.position.x, mesh.position.y, mesh.position.z, { dynamic: true })
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
      if (this.buildingLabels) this.buildingLabels.visible = this.gizmos.visible
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
    this.impactVelocity.x = preStep.x
    this.impactVelocity.y = preStep.y
    this.impactVelocity.z = preStep.z

    this.world.step(this.eventQueue)
    this.stats.steps += 1
    this.handleContacts()
    this.crushSupport(dt)
    this.projectiles.update(dt)
    this.explosions.update(dt)
    this.destruction.update(dt)
    this.buildings.update(dt)
    this.sweepDebris()
    this.reporter.update(dt)
    this.sendSnapshot(dt)
    this.updateRemotes()
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
      // A piece of a collapsing building has hit something. Marked and not acted on, for
      // the reason the comment above this method gives: shattering frees a body, and the
      // world is borrowed mutably until the drain finishes.
      if (a?.kind === "falling") this.buildings?.falling.markTouched(a.falling)
      if (b?.kind === "falling") this.buildings?.falling.markTouched(b.falling)
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
      if (!target.destructible) return

      const label = attacker.name.replace(/_/g, " ").toUpperCase()

      // A building piece knows what it is made of, so what it is made of gets a say.
      if (target.kind === "piece") {
        if (!target.building.standing(target.piece)) return

        // Raw: the piece absorbs it, and so does every cell the spread reaches.
        const damage = resolveDamage({ rules, part: attacker.part, speed: this.impactSpeed, state })
        if (damage > 0) {
          pending.push({ piece: target, damage, kind: partKind(attacker.part), key: attacker.name, label })
        }
        return
      }

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

    // Summed over the whole batch, then paid once. A car reaches several piece colliders
    // in the same step, and each of those breaks has to cost it something: paying per
    // impact would let the last one overwrite the others and make a wall three panels
    // wide as cheap as one.
    let brokenHealth = 0

    for (const impact of pending) {
      if (impact.piece) {
        brokenHealth += this.damagePiece(impact)
        continue
      }

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

    // What the wall was worth, as a speed. Damage is linear in speed by the same rule --
    // (speed - minimum_speed) * damage_per_speed -- so the health just destroyed inverts
    // back to the speed it took to destroy it, and the car pays that instead of paying
    // the solver's answer for a wall that was immovable at the time it was asked.
    if (brokenHealth > 0 && rules.damage_per_speed > 0) {
      this.vehicle.punchThrough(this.impactVelocity, brokenHealth / rules.damage_per_speed)
    }
  }

  // The small stuff -- shards, the chunks a cleared heap left -- has no bodies, so a car
  // reaching it is not a collision. It is swept by hand instead, once per car per step,
  // against the car's own box plus a margin: ours, and every other player's car we are
  // showing, because a remote car ploughing through debris on this screen has to clear it
  // on this screen.
  sweepDebris() {
    const rules = this.spec.rules.debris
    if (!rules || !this.buildings || !this.vehicle) return

    this.sweepDebrisUnder(this.vehicle.body, this.vehicle.spec, rules)
    for (const remote of this.remotes.values()) this.sweepDebrisUnder(remote.body, remote.spec, rules)
  }

  sweepDebrisUnder(body, spec, rules) {
    const t = body.translation()
    const r = body.rotation()
    const v = body.linvel()
    const [ width, height, depth ] = spec.chassis.size

    SWEEP.position.set(t.x, t.y, t.z)
    SWEEP.rotation.set(r.x, r.y, r.z, r.w)
    SWEEP.inverse.copy(SWEEP.rotation).invert()
    SWEEP.forward.set(0, 0, 1).applyQuaternion(SWEEP.rotation)
    SWEEP.velocity.set(v.x, v.y, v.z)
    SWEEP.halfX = width / 2 + rules.reach
    SWEEP.halfZ = depth / 2 + rules.reach
    // Anything below the roofline, measured from the car's centre; the box extends down
    // through the ride height to the ground, which is where debris lies.
    SWEEP.top = height / 2 + rules.reach
    this.buildings.sweepVehicle(SWEEP)
  }

  // A car resting on wreckage crushes it under its own weight, so landing on a pile means
  // sinking through it rather than perching on top of it. Wreckage is something you go
  // THROUGH, and that has to be as true of a car sitting on it as of one driving at it.
  //
  // Only ever what the WHEELS are blind to -- `supports` is filtered to that already, and
  // it is the same property that made this the thing that strands a car. So parking on a
  // roof does not quietly eat the roof: the wheels can see a roof, so the car is grounded
  // on it and never probes at all.
  //
  // Every heap under the car takes the full rate rather than a share of it. A car can come
  // down across one heap or four, and dividing would make the second case take four times
  // as long to fall through for no reason a player could see.
  //
  // No spread and no block: you go down through what is directly beneath you rather than
  // clearing a patch by sitting on it. Outside any drain callback, because breaking a
  // piece disables its collider and Rapier has the world borrowed until a drain finishes.
  crushSupport(dt) {
    const supports = this.vehicle?.supports
    if (!supports?.length) return

    const amount = this.spec.rules.support.crush * dt
    for (const handle of supports) {
      const target = this.colliderIndex.get(handle)
      if (target?.kind !== "piece" || !target.building.standing(target.piece)) continue

      target.building.damage(target.piece, amount, "impact", 0)
    }
  }

  // A piece is a fixed collider that is never freed, so unlike a prop there is nothing to
  // read before the damage lands and nothing to be careful about afterwards.
  //
  // Returns the health it destroyed, which the caller converts into the speed it cost.
  // Only pieces: a prop is a dynamic body, so the solver has already charged the car a
  // real price for shoving it and there is nothing to give back.
  damagePiece({ piece, damage, kind, key, label }) {
    const { building, piece: index } = piece
    const at = building.colliders[index].translation()

    // Which way the hit was going, so the shards carry on in that direction rather than
    // dropping straight down out of the hole.
    const from = this.vehicle.body.translation()
    const away = SCRATCH_AWAY.set(at.x - from.x, 0, at.z - from.z).normalize()

    const broken = building.damage(index, damage, kind, building.spread, away)
    this.stats.lastDamage = Math.round(damage)
    this.audio?.impact(Math.min(damage / 120, 1))
    this.damageGizmos?.registerHit(key, damage)
    this.hitMarkers.add(new THREE.Vector3(at.x, at.y + 1.0, at.z), damage, label)
    return broken
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
      this.buildingLabels?.update(entity.renderPos)
      this.damageGizmos?.update(frameTime, this.vehicle)
      this.projectiles.sync(frameTime)
      this.explosions.sync()
      this.destruction.sync()
      this.buildings?.sync()

      this.chaseCamera.update(
        frameTime, entity.renderPos, entity.renderRot,
        this.vehicle.speed, input, this.vehicle.turboActive,
        this.vehicle.drifting ? this.vehicle.driftDirection : 0,
        this.ground
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
        fallSpeed: this.fallSpeed,
        buildings: this.buildings
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
    this.buildingLabels?.dispose()
    this.damageGizmos?.dispose()
    this.hitMarkers?.dispose()
    this.projectiles?.dispose()
    this.destruction?.dispose()
    this.connection?.dispose()
    for (const remote of this.remotes?.values() ?? []) remote.dispose()
    this.remotes?.clear()
    this.buildings?.dispose(this.colliderIndex)
    this.eventQueue?.free()
    this.world?.free()

    if (this.scene) disposeScene(this.scene)
    this.renderer?.dispose()
    this.renderer?.forceContextLoss()
    this.interpolator.clear()
    this.propGrid?.clear()
    if (window.__arena === this.stats) delete window.__arena
  }
}


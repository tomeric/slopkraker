import { createConsumer } from "@rails/actioncable"

// Thin wrapper over ActionCable. The server stamps player_id, so every message carries
// an identity the sender could not forge -- including our own echo, which we drop here.
export class NetConnection {
  constructor({ match, world, playerId, onMessage, onStatus }) {
    this.playerId = playerId
    this.onMessage = onMessage
    this.onStatus = onStatus || (() => {})
    this.connected = false

    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create(
      { channel: "ArenaChannel", match, world },
      {
        connected: () => { this.connected = true; this.onStatus(true) },
        disconnected: () => { this.connected = false; this.onStatus(false) },
        received: (data) => {
          // A client receives its own broadcasts; ignore them. Server-decided messages --
          // breaks, state, error -- carry no player_id at all precisely so they get past
          // this: the client that knocked a wall out is the one that most needs to hear
          // that the house came down.
          if (!data || data.player_id === this.playerId) return
          this.onMessage(data)
        }
      }
    )
  }

  sendSnapshot(snapshot) {
    if (!this.connected) return
    this.subscription.perform("snapshot", snapshot)
  }

  // Returns whether it went, so the caller can decide what to do with a batch that did
  // not -- which for damage is to drop it and resync later rather than queue it up.
  sendDamage(payload) {
    if (!this.connected) return false
    this.subscription.perform("damage", payload)
    return true
  }

  requestState(ids) {
    if (!this.connected) return false
    this.subscription.perform("request_state", { ids })
    return true
  }

  dispose() {
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
    this.connected = false
  }
}

import { createConsumer } from "@rails/actioncable"

// Thin wrapper over ActionCable. The server stamps player_id, so every message carries
// an identity the sender could not forge -- including our own echo, which we drop here.
export class NetConnection {
  constructor({ match, playerId, onMessage, onStatus }) {
    this.playerId = playerId
    this.onMessage = onMessage
    this.onStatus = onStatus || (() => {})
    this.connected = false

    this.consumer = createConsumer()
    this.subscription = this.consumer.subscriptions.create(
      { channel: "ArenaChannel", match },
      {
        connected: () => { this.connected = true; this.onStatus(true) },
        disconnected: () => { this.connected = false; this.onStatus(false) },
        received: (data) => {
          // A client receives its own broadcasts; ignore them.
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

  dispose() {
    this.subscription?.unsubscribe()
    this.consumer?.disconnect()
    this.connected = false
  }
}

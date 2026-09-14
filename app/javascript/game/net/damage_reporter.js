// Batches the cells this client has broken and tells the server about them.
//
// Batched rather than sent per cell: one impact with spread can touch a dozen cells, and a
// dozen socket frames per hit is how a burst of rocket fire turns into a stall. The rate is
// the same snapshot_hz the vehicle relay already runs at.
//
// What is reported is the RAW damage per cell -- after this client's own spread and block
// expansion, before the material has had its say. The server runs the same absorb against
// the same table. Reporting the absorbed figure would apply the material twice; reporting
// only the cell that was touched would mean porting spread and block tiling to the server,
// which is exactly the duplication this design exists to avoid.
export class DamageReporter {
  constructor({ connection, hz = 20 }) {
    this.connection = connection
    this.interval = 1 / hz
    this.elapsed = 0
    this.queue = []
    this.seq = 0
    this.sent = 0
  }

  report(objectId, pieceIndex, raw, kind = "impact") {
    if (objectId === undefined || objectId === null) return
    this.queue.push([ objectId, pieceIndex, raw, kind ])
  }

  update(dt) {
    this.elapsed += dt
    if (this.elapsed < this.interval) return
    this.elapsed = 0
    if (this.queue.length === 0) return

    // Taken before the send: a failed send drops the batch rather than letting it grow
    // without bound while the socket is down. The server's state is authoritative, and a
    // client that reconnects asks for it again rather than replaying what it missed.
    const hits = this.queue
    this.queue = []
    if (this.connection?.sendDamage({ seq: ++this.seq, hits })) this.sent += hits.length
  }
}

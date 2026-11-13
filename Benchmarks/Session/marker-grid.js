/* Shared by the standalone guest page and the independent encoder test. */
"use strict";
globalThis.SpiceSessionMarker = {
  checksum(token) {
    return Number((token ^ (token >> 32n) ^ 0x53504943n) & 0xffffffffn);
  },
  grid(magic, first, second, checksum) {
    const bits = [];
    for (const [value, width] of [[BigInt(magic), 16], [first, 64], [second, 64], [BigInt(checksum), 32]]) {
      for (let shift = width - 1; shift >= 0; shift--) {
        bits.push(Number((value >> BigInt(shift)) & 1n));
      }
    }
    return bits;
  },
  encode(token, revision, receivedNs, drawNs) {
    const checksum = this.checksum(token);
    return [
      this.grid(0xa5c3, token, revision, checksum),
      this.grid(0xa5c4, receivedNs, drawNs, checksum),
    ];
  },
};

import { writeFile } from 'node:fs/promises';

// A soft rising two-note bell, synthesized locally; no borrowed system sound.
const rate = 32000, duration = .42, frames = Math.round(rate * duration);
const pcm = Buffer.alloc(frames * 2);
for (let i = 0; i < frames; i++) {
  const t = i / rate; let value = 0;
  for (const [start, frequency] of [[0, 1046.5], [.105, 1318.51]]) {
    const x = t - start; if (x < 0) continue;
    const envelope = (1 - Math.exp(-x * 500)) * Math.exp(-x * 20);
    const phase = 2 * Math.PI * frequency * x;
    value += envelope * (Math.sin(phase) + .12 * Math.sin(phase * 2.76)) * .24;
  }
  value *= Math.min(1, Math.max(0, (duration - t) / .04));
  pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(1, value)) * 32767), i * 2);
}
const header = Buffer.alloc(44);
header.write('RIFF'); header.writeUInt32LE(36 + pcm.length, 4); header.write('WAVEfmt ', 8);
header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate * 2, 28);
header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write('data', 36); header.writeUInt32LE(pcm.length, 40);
await writeFile('public/audio/whale-maid/wake-chime.wav', Buffer.concat([header, pcm]));

export function sampleSpeech(frames, time) {
  if (!frames.length || time < 0 || time >= frames.at(-1)[0]) return { open: 0, ee: 0, ou: 0 };
  let low = 0, high = frames.length - 1;
  while (high - low > 1) { const mid = (low + high) >> 1; if (frames[mid][0] <= time) low = mid; else high = mid; }
  const a = frames[low], b = frames[high], t = Math.max(0, Math.min(1, (time - a[0]) / Math.max(.001, b[0] - a[0])));
  const blend = i => a[i] + (b[i] - a[i]) * t;
  return { open: blend(1), ee: blend(2), ou: blend(3) };
}

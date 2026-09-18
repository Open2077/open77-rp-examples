// Generates sfx/afterlife_ambience.wav: a royalty-free, fully synthesized club
// ambience loop (a sub bass throb, a muffled four-on-the-floor kick, a pink-ish
// crowd murmur). No sample, no recording, no third-party material -- every byte
// comes from the math below, so the resource may ship it.
//
//   node tools/make-ambience.mjs            (run from the resource directory)
//
// Output: mono, 22050 Hz, 16-bit PCM, 12 s (24 beats at 120 BPM), 529 KB,
// under the 1 MiB clip cap of open77_sound. The loop point is clean: every
// periodic component completes a whole number of cycles in 12 s and the noise
// bed is crossfaded onto itself.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const rate = 22050;
const seconds = 12;
const frames = rate * seconds;
const out = new Float32Array(frames);

// Deterministic PRNG so the file is reproducible byte for byte.
let seed = 0x5eed77;
function rand() {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 4294967296;
}

// 1. Sub bass drone: 55 Hz + 110 Hz, slowly breathing (0.25 Hz => 3 cycles / 12 s).
for (let i = 0; i < frames; i++) {
    const t = i / rate;
    const breathe = 0.6 + 0.4 * Math.sin(2 * Math.PI * 0.25 * t);
    out[i] += 0.16 * breathe * (Math.sin(2 * Math.PI * 55 * t) + 0.5 * Math.sin(2 * Math.PI * 110 * t));
}

// 2. Muffled kick every beat (120 BPM => 0.5 s), a pitch-dropping sine burst.
const beat = 0.5;
for (let b = 0; b < seconds / beat; b++) {
    const start = Math.floor(b * beat * rate);
    const length = Math.floor(0.22 * rate);
    for (let n = 0; n < length && start + n < frames; n++) {
        const t = n / rate;
        const env = Math.exp(-t * 18);
        const freq = 48 + 90 * Math.exp(-t * 40);
        out[start + n] += 0.42 * env * Math.sin(2 * Math.PI * freq * t);
    }
}

// 3. Crowd murmur: low-passed noise with a slow random amplitude wander.
const noise = new Float32Array(frames + rate); // one extra second for the crossfade
let lp1 = 0, lp2 = 0, wander = 0.5;
for (let i = 0; i < noise.length; i++) {
    const white = rand() * 2 - 1;
    lp1 += 0.035 * (white - lp1);   // ~120 Hz corner at 22050 Hz
    lp2 += 0.035 * (lp1 - lp2);
    if (i % 2205 === 0) wander = 0.35 + 0.4 * rand();
    noise[i] = lp2 * 4.5 * wander;
}
const fade = rate; // crossfade the last second onto the first second
for (let i = 0; i < frames; i++) {
    let v = noise[i];
    if (i < fade) {
        const k = i / fade;
        v = noise[i] * k + noise[frames + i] * (1 - k);
    }
    out[i] += 0.22 * v;
}

// 4. Soft clip and 16-bit PCM.
const pcm = Buffer.alloc(frames * 2);
for (let i = 0; i < frames; i++) {
    const v = Math.tanh(out[i]);
    pcm.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(v * 32767 * 0.9))), i * 2);
}

const header = Buffer.alloc(44);
header.write("RIFF", 0);
header.writeUInt32LE(36 + pcm.length, 4);
header.write("WAVE", 8);
header.write("fmt ", 12);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20);        // PCM
header.writeUInt16LE(1, 22);        // mono
header.writeUInt32LE(rate, 24);
header.writeUInt32LE(rate * 2, 28); // byte rate
header.writeUInt16LE(2, 32);        // block align
header.writeUInt16LE(16, 34);       // bits per sample
header.write("data", 36);
header.writeUInt32LE(pcm.length, 40);

const here = dirname(fileURLToPath(import.meta.url));
const target = join(here, "..", "sfx", "afterlife_ambience.wav");
mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, Buffer.concat([header, pcm]));
console.log(`wrote ${target} (${header.length + pcm.length} bytes, ${seconds} s @ ${rate} Hz mono)`);

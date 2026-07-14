# Stage 2 — Button-to-Photon Latency (inputLagTimer + high-speed video)

This measures **true end-to-end latency**: physical button/stick motion → the moment the
screen reacts. It is a *different, larger* quantity than the Stage 1 polling interval — it
includes controller report time + USB/Bluetooth + OS + game logic + render + display
response. No extra hardware beyond a phone that shoots slow-motion video.

## Why multiple clips

A single measurement is noisy: the camera samples at a finite framerate (each frame = a
quantization step), panel response varies by pixel/color, and exactly which frame motion
crosses the detection threshold shifts the number. Record several clips and pool every
detected event → a defensible **median + spread** instead of one jittery figure.

Framerate → resolution floor: 240 fps = 4.17 ms/frame, so a single measurement is only
good to ±~4 ms; 120 fps = ±~8 ms. Prefer the highest framerate your phone reaches *with
enough light* (see gotchas).

## Recording the clips

1. **Framerate:** use your phone's Slo-mo mode — 240 fps if available (iPhone/many Androids
   do 240; some do 480/960). More fps = finer latency resolution.
2. **Frame both things at once:** the controller AND the screen must be in the same shot —
   e.g. the controller in the foreground, the monitor behind it. You need to see the input
   move and the screen react in the same video.
3. **Tripod, always.** inputLagTimer is motion-detection based; handheld footage spams false
   positives. Brace the phone if you have no tripod.
4. **Pick a clean input→output pair** with a fast, obvious on-screen response:
   - Best: an in-game action with near-instant visual feedback (fire button → muzzle flash;
     jump → character leaves ground; menu button → highlight moves).
   - Keep the responding screen area small and high-contrast.
5. **Reduce stray motion:** disable controller vibration; rest the controller on a surface so
   only the button/stick you press moves.
6. **Light it well.** Slo-mo needs light; a dim scene makes the phone silently drop to a
   lower real framerate (duplicated frames). If unsure, add light or record at a framerate
   the phone can actually sustain.
7. **Anti-flicker:** under mains-powered LED/fluorescent light, use the phone's anti-flicker
   or a framerate different from your mains frequency (50/60 Hz), or you'll get flicker that
   trips motion detection.
8. Do **8–12 button presses per clip**, or several short clips. Each press = one latency
   event. Aim for ≥20 pooled events total across clips.
9. Copy the clips into `./clips/` (create it): `mkdir -p clips` and drop the `.mp4`/`.mov` in.

## Analyzing

```bash
# Per-clip interactive marking, then automatic pooling:
./stage2_measure.sh clips/

# Or a single clip, then aggregate separately:
inputLagTimer/.venv/bin/python inputLagTimer/inputLagTimer.py clips/run1.mp4
python3 stage2_aggregate.py clips/
```

Inside inputLagTimer, per clip:
1. Press **S**, drag the **🟦blue** rectangle over the moving input (button/stick).
2. Drag the **🟪purple** rectangle over the screen area that reacts.
3. Watch the two motion bars at the top. Press **1/2** (input threshold) and **3/4** (output
   threshold) to set each white marker just above the noise floor — real motion should cross
   it, idle noise should not.
4. Let the clip play; it records multiple latency events (min/avg/max shown on screen).
5. Press **ESC** to exit — our patch writes `clips/<name>.result.json`.
6. `.cfg` is saved per clip so you can re-run with identical settings.

`stage2_aggregate.py` then prints per-clip medians and the **pooled median, mean, std dev,
and IQR** across every event.

## Gotchas that skew the number (from the tool author + macOS specifics)

- **Rolling shutter:** phone cameras expose top-to-bottom; one image corner is recorded
  before the other, slightly skewing timing. Global-shutter cameras avoid it.
- **Where on the screen you measure:** displays refresh top→bottom, so the output rectangle's
  vertical position shifts the result by up to one refresh interval. Keep it consistent
  between clips.
- **Panel response varies** by color transition (white↔black vs black↔white) and panel type
  (OLED ≫ LCD), and by monitor settings (game mode, overdrive). This is *real* latency, but
  means you can only compare clips measured under identical display settings.
- **ProMotion / variable refresh (macOS):** a 120 Hz display halves the display contribution
  vs 60 Hz. Note the refresh rate you tested at; don't compare 60 Hz and 120 Hz clips.
- **Backgrounded-app throttling (macOS):** keep the game/app in the foreground while
  recording; macOS throttles background apps, inflating latency unrepresentatively.

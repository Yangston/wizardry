# Experimental live computer and iPhone volume

The intended flow is **wake Watch → double finger touch → hold still → ready haptic → extend past 55° yaw → twist like a knob → lock**.

Use the existing AssistiveTouch **Activate Wizardry** Shortcut assignment for double finger touch. Assign AssistiveTouch single touch to **None**. Wizardry's optional personalized detector recognizes single touches itself; before enrollment, use **Lock volume**. Manual **Arm** performs the same initial hold-still calibration. There is no twist-to-wake sequence.

## Connect and adjust

1. Install both updated apps. Connect **Computer** or **Phone** from the Watch or iPhone control screen. Only one command target is active, and the paired iPhone relays every Watch command. **Disconnect** stops Wizardry control without unpairing devices or deleting saved receiver credentials.
2. For Computer, pair the updated receiver using its address and token, then run it with `--execute`. Without `--execute`, acknowledgements are explicitly dry runs starting at 50%. Phone live volume does not require a computer receiver.
3. Activate while looking at the Watch and hold still for 250 ms until the ready haptic. Extend until the absolute wrapped z / yaw change reaches **55°** from that ready pose. Either direction qualifies. Entry occurs on the first fresh sample across the threshold, without another stillness delay or an upper-angle cutoff. Pure yaw does not change the watch-face normal, so normals are not the entry criterion.
4. The selected output reads its actual volume without changing it; the current roll becomes the knob baseline. Twist slightly positive to increase volume or negative to decrease it. **90° changes volume by 50 percentage points; 180° spans the full 0–100% range.** Wrapped roll deltas avoid jumps across ±180°. At 0% or 100%, reversing responds immediately without undoing extra outward rotation first. Raising/lowering and pitch are not the volume inputs.
5. Hold still to retain the current level, then resume twisting without reactivation. Crossing the viewing yaw does not exit volume. Existing discrete twist/tilt/shake actions remain suppressed until fresh activation after volume ends.
6. Press **Lock volume**, or use a learned single thumb-index touch. **Locking** means the final request is pending; **Locked** means the selected output confirmed the final level and closed the session. Requested and acknowledged percentages remain separate; a dry-run acknowledgement is not audio execution.

A learned tap waits 450 ms from candidate onset for possible double-touch cancellation; a second candidate can add classification latency. During a deliberate sensing/tap freeze, the knob rebases to the current roll so hidden movement is not replayed afterward.

Holding still has **no five-second auto-exit**. Live volume ends on lock, explicit disconnect/stop, session expiry, relevant settings changes, backgrounding, interrupted sensing, or transport failure. Activate again after an interaction ends. Temporary autorotation begins with foreground calibration and retains the same lease through readiness, adjustment, stationary pauses, and final acknowledgement. The cap is ten minutes from calibration and the outer session's remaining duration. Inactive calibration requires a valid lease and fresh samples; backgrounding cancels it. No extended runtime session, artificial workout, or silent audio is used.

**Physical display acceptance remains pending:** during movement and stationary pauses, the Watch must stay awake in sideways, palm-up, and backward-tilt poses. Continued processing alone does not prove that the display stayed awake. The user reported rotation working in **0.2.0 (15.1)**. Build **16.1** added stationary-hold behavior, but physical hold, full pose coverage, and battery checks are not established. Autorotation is not an indefinite display-wake guarantee.

## Live iPhone volume (experimental)

1. Connect **Phone** and keep Wizardry foreground on iPhone with its native volume slider visible on Control, Live, or Setup. Spotify authorization, computer pairing, and volume Shortcuts are unnecessary for this path.
2. Use the same initial calibration, immediate 55° yaw entry, and signed twist-knob adjustment as Computer. Begin reads current iPhone media volume without setting it.
3. The bridge now hosts an ordinary `MPVolumeView` rather than subclassing that native control. It sends public `UISlider` value/control events and reads `AVAudioSession.outputVolume`. Fixing the unsupported subclass path is not physical-device validation. Requested and acknowledged values stay separate: confirmation requires actual readback within one percentage point of the requested level, not just a moved slider.
4. Lock sends the frozen final level and closes after readback. The applied level remains in place. Holding still and crossing the ready yaw do not end adjustment; session/runtime caps and explicit interruptions still apply.
5. Leaving or inactivating Wizardry on iPhone, an unavailable/offscreen slider, audio-route changes, failed readback, invalid ordering, and expired requests stop adjustment. Each write is attempted once, with up to 400 ms for readback inside the original one-second deadline. One write executes while only the newest unsent target waits. Superseded targets are not confirmed volume changes; failure discards pending work without retries.

**Platform boundary:** Apple does not document a programmatic system-volume setter. This bridge depends on the native control exposing an enabled public slider that responds to control events. No private class names or selectors are used. Real output control, route behavior, timing, and compatibility remain experimental until tested on the user's physical iPhone. The Simulator returns an explicit unsupported error. This controls media volume, not ringer/alert volume, and cannot control a locked/background iPhone. Native slider touch and Watch Now Playing remain available.

The existing discrete Phone twist mappings still launch the named Volume Up/Down Shortcuts. Extension takes priority, and those discrete mappings remain suppressed throughout knob adjustment. The live knob does not launch a volume Shortcut.

### iPhone acceptance checks (pending physical testing)

- [ ] Record iPhone/iOS, Watch/watchOS, wrist and crown orientation, output route, and actual delivered rates.
- [ ] Begin at several known levels without changing them. Small positive twists increase audible volume; small negative twists decrease it before lock. Test a ±180° wrap crossing without a volume jump.
- [ ] Compare actual system volume with requested and acknowledged levels, including 0%/100%. Confirm immediate reverse response at either limit. Measure movement-to-applied-volume timing separately from acknowledgement arrival rate.
- [ ] Lock with the button, then with an enrolled single touch. The final level holds, and discrete gestures remain suppressed until reactivation.
- [ ] Hold still for 10–30 seconds: the physical display stays awake, volume stays constant, and twisting resumes adjustment without reactivation. Verify one-second heartbeats and the existing ten-minute cap.
- [ ] Lock iPhone, switch apps, hide the slider, disconnect the Watch, or change speaker/headphone/AirPlay routes mid-adjustment. Pending updates cannot replay on recovery.
- [ ] Verify music continues while Wizardry starts/stops its mixing ambient audio session. Test speaker and headphones separately; AirPlay remains unverified until tested.
- [ ] Confirm Computer and existing discrete mappings still work only for the selected connected target.

## Learn the single touch

Open **Learn single finger tap** on the Watch. Wear it snugly, keep Wizardry visible, and follow each step. Enrollment disables mapped actions. This personalized tap setup is separate from desktop named movement recordings.

If enrollment is already frontmost, **Activate Wizardry** clears pending control input but preserves the training recording instead of arming. Tap recognition is disabled while recording, allowing the instructed negative double-touch trials with the existing AssistiveTouch assignment. Leaving the app or interrupted sensing cancels enrollment.

| Step | Instructions | Recording |
| --- | --- | --- |
| Stationary | Exactly 20 single touches, roughly one per second | 25 s |
| Moving | Exactly 20 single touches while gently moving | 25 s |
| Other movements | No singles; isolated extensions, stops, twists, clenches, shakes, and double touches | 60 s |
| New tap trials | Exactly 20 singles, mixing still and moving | 25 s |
| New non-tap trials | Natural movements and double touches, no singles | 5 min |

At least 30 training tap windows and five isolated negative windows are required. Double-touch pairs use temporal cancellation instead of labeling each touch as a negative single-touch template. Dynamic time warping compares six-channel high-pass acceleration/rotation features. The model requires at least 19 of 20 tap candidates and at most one false candidate in five minutes before enabling custom tap input.

These counts assume the instructed number of touches; they are a personalized setup check, not independent research measurements. Insufficient examples, interruptions, or raw delivery below 70 Hz require repeating the step. Enrollment never disables the onscreen Lock button. **Forget tap learning** removes the model. Tap templates stay on the Watch.

## Computer studio and named recordings

Enable **Computer studio** on the foreground iPhone and keep Wizardry visible on the Watch. The receiver's **Live sensors** page can request monitoring independently of the selected command target. The iPhone is always the relay, including when Phone remains the active output.

In **Record movements**, create a named movement, then select **Record example**. During **Preparing**, hold still. Move only after Watch confirmation and **Recording — move now**. Capture suppresses Watch gesture actions. **Stop & save** persists the recording on the local computer under `receiver/data/`; **Cancel** discards it. The 60-second limit and interruption handling retain quality evidence for incomplete takes. Only samples explicitly confirmed as recording are saved.

**Map movements** stores named custom movements and action labels for later training. Those recordings and labels do not create or deploy a trained recognizer. Existing Computer/Phone discrete mappings are a separate editable configuration: desktop edits require an acknowledgement from the iPhone for the expected configuration revision. Home targets remain editable on iPhone. See the [receiver guide](../receiver/README.md) for studio pages and local files.

## Protocol and failure behavior

- Authenticated `/volume` requests use `begin`, `update`, and `end`, with UUID request/session identities, configuration revision, increasing sequence, creation time, and a normalized update/end target. New app requests also identify the selected control profile. Begin uses sequence zero without a target. Connection/profile changes invalidate old control work.
- Requests expire after one second, allowing up to 100 ms positive clock tolerance. Backend sessions retain six-second missing-request watchdogs; a healthy stationary session sends an unchanged-volume heartbeat each second. Heartbeats never extend runtime caps or bypass stale sensing.
- Before Computer begin, the iPhone samples receiver time through authenticated ping and translates request times into that clock domain. Replies refresh the sample. The original Watch/iPhone deadline remains enforced, including clock sampling time. Alignment never retries or freshens an expired request.
- The Watch starts updates at most every 20 ms (50 Hz), with at most four outstanding updates and one newest local target. A full window waits for a reply. End freezes its final target and uses an independent priority slot.
- The iPhone serializes one executing write plus one newest waiting target. Replaced updates receive `superseded` without a volume value. End supersedes waiting updates and runs after the executing write. The receiver uses a 50/s token bucket with burst capacity four; end bypasses the limiter and closes the session before I/O.
- Transport v2 requires both updated apps and, for Computer, the updated receiver. Authenticated receiver ping advertises `liveVolumeProtocol: 2`; begin replies include `transportVersion: 2`. Missing capability produces an update-required failure before adjustment. The new receiver can still accept legacy 20 Hz clients.
- Stale sensing, network errors, and missing final acknowledgements discard pending targets without retries or later replay. Failed lock means **stopped, unconfirmed**. An accepted request may have executed even if its reply was lost.
- Receiver errors distinguish authentication, missing routes, expiry/clock, ordering, rate limit, and audio-device failures. Pairing credentials are redacted. Core Audio targets the current default multimedia endpoint and preserves mute; changing endpoints ends the session instead of silently controlling another output.

## Physical-device acceptance record

Synthetic replay and CI validate control logic; actual roll direction, personalized touch recognition, paired delivery, display behavior, and output latency still require hardware testing.

| Measurement | Target | Current physical result |
| --- | --- | --- |
| Entry | First fresh sample at ±55° wrapped ready-pose yaw; no extra settling delay | Not measured |
| Knob direction and sensitivity | Positive increases; negative decreases; 90° changes 50 percentage points | Not measured |
| Wrap and limits | No jump across ±180°; reversal at 0%/100% responds immediately | Not measured |
| Single-touch recall, separate end-to-end trials | ≥95% | Not measured |
| False actions during ordinary/negative activity | ≤1 per 5 min | Not measured |
| Volume drift during a five-second stationary hold | ≤2 percentage points | Not measured |
| Stationary hold, 10–30 seconds | Display awake; volume constant; twist resumes without reactivation | Not measured |
| Movement-to-applied-volume latency, median | ≤350 ms | Not measured |
| Actual applied updates while targets change, both outputs | ≥30 Hz; p95 inter-update gap ≤60 ms | Not measured |
| Display sideways, palm-up, backward tilt, and crossing viewing yaw | Awake throughout; no unintended exit | Not measured |
| AssistiveTouch double activation | Does not accidentally lock | Not measured |
| Target switch, disconnect, explicit stop, and interruptions | No stale action or replay | Not measured |

For **both** Computer and Phone, perform three 15-second trials of small positive/negative twists while sideways, palm-up, backward tilted, and crossing the viewing yaw. Avoid 0%/100% saturation during cadence measurements. Observe the physical display and measure successful applied/read-back timestamps separately from Watch reply arrivals. Repeat without an attached debugger. Record hardware/OS, wrist/crown orientation, delivered rates, receiver mode, trial counts, drift, false actions, latency, and battery observations. Pending fields must not be replaced with simulator results.

## Motion, awake, and transport diagnostics

Watch and iPhone show wrapped **Yaw change from ready pose**; extension enters at +55° or −55°. During adjustment, signed twist degrees are relative to the volume-entry roll and angular speed is degrees per second. These are angle measurements, not height/travel estimates. Control displays starting, requested, and acknowledged levels; stale data and dry runs are marked separately. All sensor axes remain available for inspection.

Capture requests 100 Hz. Ordinary phone display samples remain bounded at up to 20 Hz with approximately 100 ms batches; busy telemetry drops unsent batches instead of building a replay queue. Desktop Studio uses its separate explicit sensor/recording subscription. Actual delivery rate and physical direction still require Watch measurements.

**Awake diagnostics** reports scene/application state, requested/read-back autorotation, interface rotation, reduced luminance, raw/device-motion rates, sample age, processing delay, maximum gap, confirmed acknowledgement Hz, round-trip time, outstanding updates, and typed stop reason. The Watch retains up to 48 credential-free transition events. Confirmed acknowledgement Hz measures replies, not physical output application timing. Correlate lifecycle/release events with observation; a true autorotation readback does not prove that the display stayed awake.

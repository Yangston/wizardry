# Experimental live computer volume

The intended flow is **wake watch → double finger touch → ready haptic while looking at the watch → extend arm → raise/lower hand → one single finger touch to lock**.

The double touch uses the user's existing AssistiveTouch **Activate Wizardry** Shortcut assignment. Assign AssistiveTouch's single touch to **None**. Wizardry learns and detects the single touch itself; it does not receive Apple's single-touch recognition events. Manual **Arm** follows the same hold-still calibration. There is no twist-to-wake sequence.

## Setup and use

1. Update both apps and the Windows receiver. Pair the receiver, run it with `--execute`, and select the Computer profile. Without `--execute`, volume acknowledgements are explicitly dry runs starting at 50%.
2. Activate while looking at the watch; hold still for 250 ms. Extension has priority over discrete gestures. The wrapped z / yaw change must reach 70–110 degrees from the ready pose and settle for 250 ms. Either sign is accepted. A pure yaw turn does not change the watch-face normal, so normals are not the extension criterion.
3. The receiver reads Windows' current default multimedia output volume. Wait for the entry haptic, then make short upward/downward movements with pauses. About 20 cm adds/subtracts 20 percentage points. A pause holds the current volume and resets estimated velocity; it does not snap to a physical height.
4. Use **Lock volume** before enrolling your tap. After enrollment, a single thumb-index touch locks. The detector waits 450 ms from its candidate onset for a possible second touch. Classification can add latency if a second candidate is still being evaluated.
5. **Locking** means the final request is pending. **Locked** means the receiver acknowledged the final value and closed the session. Requested and acknowledged percentages, yaw change, mode and tap status appear on the Watch and on iPhone Control / Live; dry-run acknowledgement is not audio execution.

Volume ends after five seconds without meaningful movement, returning to within 25 degrees of the viewing yaw for 250 ms, session expiry, settings changes, leaving the app, or interrupted sensing. Activate again before another adjustment. Brief inactive foreground periods may continue only while fresh samples arrive. No additional background runtime is requested.

## Learn the single touch

Open **Learn single finger tap** on the Watch. Wear it snugly, keep Wizardry visible, and start each step only after reading its instructions. Recording disables mapped actions.

While a recording is already frontmost, the Activate Wizardry shortcut clears pending control input but preserves the complete training recording instead of arming controls. The tap recognition model is disabled during recording. This allows the instructed double-touch negative trials with your existing AssistiveTouch assignment. Leaving the app or interrupted sensing still cancels the recording.

| Step | Instructions | Recording |
| --- | --- | --- |
| Stationary | Exactly 20 single touches, roughly one per second | 25 s |
| Moving | Exactly 20 single touches while gently raising/lowering | 25 s |
| Other movements | No single touches; isolated extensions, stops, twists, clenches, shakes, plus double touches | 60 s |
| New tap trials | Exactly 20 singles, mixing still and moving | 25 s |
| New non-tap trials | Natural movements and double touches, no singles | 5 min |

At least 30 training tap windows and five isolated negative windows are required. Double-touch pairs are handled by temporal cancellation rather than labeling their individual touches as negative single-touch templates. Dynamic time warping matches six-channel high-pass acceleration/rotation features against positive and negative templates. A threshold is selected from held-out recordings; the model requires at least 19 of 20 tap candidates and at most one false single-touch candidate in five minutes to enable custom tap input.

Enrollment counts assume you perform the instructed number of touches. They are a personalized setup check, not independent research measurements. Insufficient examples, interrupted capture, or less than 70 Hz raw delivery require repeating the step. Enrollment has no effect on the onscreen Lock button. **Forget tap learning** removes the saved model. Templates remain on the Watch; this feature does not upload recordings.

## Protocol and failure behavior

- `/volume` accepts authenticated `begin`, `update`, and `end` JSON requests containing UUID `id` and `sessionID`, `revision`, monotonic-in-session integer `sequence`, wall-clock `createdAt`, and normalized `target` for update/end. Begin uses sequence zero without a target.
- Requests expire after one second, with up to 100 ms positive clock tolerance. Phone and receiver validate identities and order. Receiver sessions expire after six seconds without a request; unchanged live volume gets a heartbeat update each second.
- Before begin, the phone samples receiver time through an authenticated ping and translates timestamps into the receiver clock domain. Each acknowledgement refreshes that sample. The original Watch/phone one-second deadline is also enforced, including time spent sampling the clock; return-trip delay makes the translated age more conservative. Clock alignment never retries or freshens an expired command.
- The Watch allows one in-flight volume request and coalesces to the newest target, at no more than five updates per second. End bypasses the update limiter and drains after the current reply; the receiver rejects every later command for that session.
- Network, stale-sample, and final-ack failures discard pending targets. No automatic retries or later replay occur. A failed lock is shown as **stopped, unconfirmed**. A request already accepted by the receiver may have executed even if its reply was lost.
- HTTP rejection messages identify the status and server reason: 401/403 pairing token, 404/405 missing live-volume route, 408 expiry/clock, 409 session ordering, 429 rate limit, 503 audio device. A missing receiver time sample asks you to update/restart the receiver. Pairing tokens are redacted from displayed server errors.
- Core Audio controls the default multimedia render endpoint, preserving mute state. Changing the default endpoint ends the session rather than silently adjusting a different device. Existing key-based commands retain their original behavior.

## Physical-device acceptance record

Synthetic replay and CI validate control logic; actual finger recognition, inertial drift, paired delivery, and latency remain unverified until measured on hardware. Acceleration-only height estimation drifts, and constant-velocity motion can resemble rest. Use short movements with pauses.

| Measurement | Target | Current physical-device result |
| --- | --- | --- |
| Single-touch recall, separate end-to-end trials | ≥95% | Not measured |
| False actions during ordinary/negative activity | ≤1 per 5 min | Not measured |
| Volume drift during a five-second stationary hold | ≤2 percentage points | Not measured |
| Movement-to-applied-volume latency, median | ≤350 ms | Not measured |
| AssistiveTouch double activation does not lock accidentally | Pass | Not measured |
| Left/right wrist, crown orientation, screen dimming, interruption | Pass | Not measured |

Record watch model, watchOS version, wrist/crown orientation, delivered raw/device-motion rates, receiver mode, trial counts, false actions, drift, measured latency, and battery observations when testing. Do not replace these pending fields with simulator results.


## Yaw diagnostics

The iPhone Control and Live screens show the wrapped **Yaw change from ready pose**. Looking at the Watch at the ready haptic establishes zero; extension should approach +90 or -90 degrees. The attitude graph retains raw yaw for comparison. Entry is 70-110 degrees held for 250 ms; return-to-viewing uses less than 25 degrees. If motion becomes stale, the phone labels readings as last received rather than live. Control and Live request bounded local telemetry while foreground; other tabs stop the stream.

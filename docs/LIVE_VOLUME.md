# Experimental live computer volume

The intended flow is **wake watch → double finger touch → ready haptic while looking at the watch → extend arm → raise/lower hand → one single finger touch to lock**.

The double touch uses the user's existing AssistiveTouch **Activate Wizardry** Shortcut assignment. Assign AssistiveTouch's single touch to **None**. Wizardry learns and detects the single touch itself; it does not receive Apple's single-touch recognition events. Manual **Arm** follows the same hold-still calibration. There is no twist-to-wake sequence.

## Setup and use

1. Update both apps and the Windows receiver. Pair the receiver, run it with `--execute`, and select the Computer profile. Without `--execute`, volume acknowledgements are explicitly dry runs starting at 50%.
2. Activate while looking at the watch; hold still for 250 ms. Extension has priority over discrete gestures. The watch-face normal must turn 70–110 degrees from the calibrated pose and settle for 250 ms.
3. The receiver reads Windows' current default multimedia output volume. Wait for the entry haptic, then make short upward/downward movements with pauses. About 20 cm adds/subtracts 20 percentage points. A pause holds the current volume and resets estimated velocity; it does not snap to a physical height.
4. Use **Lock volume** before enrolling your tap. After enrollment, a single thumb-index touch locks. The detector waits 450 ms from its candidate onset for a possible second touch. Classification can add latency if a second candidate is still being evaluated.
5. **Locking** means the final request is pending. **Locked** means the receiver acknowledged the final value and closed the session. Requested and acknowledged percentages are displayed separately; dry-run acknowledgement is not audio execution.

Volume ends after five seconds without meaningful movement, returning to the viewing pose for 250 ms, session expiry, settings changes, leaving the app, or interrupted sensing. Activate again before another adjustment. Brief inactive foreground periods may continue only while fresh samples arrive. No additional background runtime is requested.

## Learn the single touch

Open **Learn single finger tap** on the Watch. Wear it snugly, keep Wizardry visible, and start each step only after reading its instructions. Recording disables mapped actions.

While a recording is already frontmost, the Activate Wizardry shortcut clears pending recognition but preserves the enrollment recording instead of arming controls. This allows the instructed double-touch negative trials with your existing AssistiveTouch assignment. Leaving the app or interrupted sensing still cancels the recording.

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
- The Watch allows one in-flight volume request and coalesces to the newest target, at no more than five updates per second. End bypasses the update limiter and drains after the current reply; the receiver rejects every later command for that session.
- Network, stale-sample, and final-ack failures discard pending targets. No automatic retries or later replay occur. A failed lock is shown as **stopped, unconfirmed**. A request already accepted by the receiver may have executed even if its reply was lost.
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

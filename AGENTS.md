# Wizardry project decisions

- The user's confirmed touch-free entry is wrist wake, then an AssistiveTouch **double finger touch** assigned to **Activate Wizardry**. The shortcut already arms after hold-still calibration. Do not reintroduce an additional twist-to-wake mechanism.
- AssistiveTouch single finger touch is assigned to **None**. Wizardry owns custom, personalized single-touch recognition and routes the input according to interaction context. Its first action is locking live computer volume.
- Volume entry is a roughly orthogonal watch-face pose relative to the calibrated looking-at-watch pose. Adjustment uses straight vertical translation, not arm pitch as a substitute.
- Keep existing discrete gesture mappings. Extension has priority; volume mode suppresses those actions until fresh activation.
- Short-stroke height estimation and finger-touch recognition are experimental. CI/synthetic tests do not establish physical-watch accuracy, suspension behavior, latency, or battery life.
- Preserve immediate delivery, expiry, session ordering, dry runs, pairing-token privacy, and no automatic command retries. No artificial workouts or silent audio for background runtime.

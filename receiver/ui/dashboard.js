"use strict";
const $ = (id) => document.getElementById(id);
let preview = false;
let previewStart = 0;
let latest = null;
let lastEvents = "";
let lastMovement = "holding";
let lastVolumeAt = null;
let lastVolume = null;
const labels = {waiting: "Waiting", live: "Adjusting", locked: "Locked", interrupted: "Stopped · unconfirmed"};

function setText(id, value) { if ($(id).textContent !== String(value)) $(id).textContent = value; }
function formatAge(seconds) {
  if (seconds < 1) return "Just now";
  if (seconds < 60) return `${Math.floor(seconds)}s ago`;
  return `${Math.floor(seconds / 60)}m ago`;
}
function renderChart(state) {
  const points = state.history.filter((p) => p.time >= state.serverTime - 30);
  const coords = points.map((p) => [Math.max(0, Math.min(640, (p.time - state.serverTime + 30) / 30 * 640)), 170 - p.volume * 160]);
  const path = coords.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(2)},${y.toFixed(2)}`).join(" ");
  $("chart-line").setAttribute("d", path);
  $("chart-area").setAttribute("d", coords.length > 1 ? `${path} L${coords.at(-1)[0]},170 L${coords[0][0]},170 Z` : "");
  $("chart-point").setAttribute("visibility", coords.length ? "visible" : "hidden");
  if (coords.length) {
    $("chart-point").setAttribute("cx", coords.at(-1)[0]);
    $("chart-point").setAttribute("cy", coords.at(-1)[1]);
  }
  $("chart-empty").hidden = coords.length > 0;
  $("chart-empty").style.display = coords.length ? "none" : "grid";
  setText("chart-empty", state.history.length ? "No confirmed values in the last 30 seconds." : "Your volume changes will appear here.");
}
function renderEvents(events) {
  const key = `${preview}:${events.map((event) => event.id).join(",")}`;
  if (key === lastEvents) return;
  lastEvents = key;
  $("events").replaceChildren();
  if (!events.length) {
    const empty = document.createElement("li");
    empty.className = "empty-event";
    empty.textContent = "Listening for your first action…";
    $("events").append(empty);
  }
  for (const event of events) {
    const row = document.createElement("li");
    const dot = document.createElement("span");
    dot.className = `event-dot ${event.kind}`;
    const label = document.createElement("span");
    label.textContent = event.label;
    const time = document.createElement("time");
    time.dateTime = new Date(event.time * 1000).toISOString();
    time.textContent = new Date(event.time * 1000).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit", second: "2-digit"});
    row.append(dot, label, time);
    $("events").append(row);
  }
}
function render(state, online = true) {
  const stale = state.volumeAt !== null && state.serverTime - state.volumeAt > 1.5;
  const phase = !online && state.phase === "live" ? "interrupted" : state.phase;
  setText("connection-label", preview ? "Visual preview" : online ? "Receiver online" : "Receiver offline");
  $("connection").className = `connection${online ? "" : " offline"}`;
  setText("mode", preview ? "PREVIEW · SIMULATED" : state.execute === null ? "RECEIVER UNAVAILABLE" : state.execute ? "EXECUTE · WINDOWS AUDIO" : "DRY RUN · NO AUDIO CHANGES");
  $("mode").className = `mode${state.execute && !preview ? " execute" : ""}`;
  setText("footer-mode", preview ? "Preview never controls your computer" : state.execute === null ? "Waiting for receiver status" : state.execute ? "Windows audio execution enabled" : "Dry run · values are simulated");
  setText("phase", labels[phase]);
  $("phase").className = `phase ${phase}`;
  setText("volume", state.volume === null ? "—" : Math.round(state.volume * 100));
  if (state.volume === null) $("volume-meter").removeAttribute("aria-valuenow");
  else $("volume-meter").setAttribute("aria-valuenow", Math.round(state.volume * 100));
  $("volume-meter").setAttribute("aria-valuetext", state.volume === null ? "Waiting for volume" : `${Math.round(state.volume * 100)} percent${preview || !state.execute ? ", simulated" : ", last confirmed"}`);
  $("dial-fill").style.strokeDashoffset = 735.133 * (1 - (state.volume ?? 0));
  setText("volume-caption", state.volume === null ? "Waiting for the first live-volume session" : !online ? "Last received value · receiver unavailable" : preview ? "Simulated volume · preview only" : state.execute ? "Last confirmed live volume · Windows audio" : "Simulated volume · no audio changes");
  setText("anchor", state.anchor === null ? "—" : `${Math.round(state.anchor * 100)}%`);
  const delta = state.volume === null ? null : Math.round((state.volume - state.anchor) * 100);
  setText("delta", delta === null ? "—" : `${delta > 0 ? "+" : ""}${delta} pp`);
  setText("age", state.volumeAt === null ? "—" : formatAge(state.serverTime - state.volumeAt));
  if (state.volumeAt !== lastVolumeAt) {
    lastMovement = lastVolume !== null && state.volume > lastVolume + .002 ? "raising" : lastVolume !== null && state.volume < lastVolume - .002 ? "lowering" : "holding";
    lastVolume = state.volume;
    lastVolumeAt = state.volumeAt;
  }
  const motion = !online ? ["Receiver unavailable", "Restart the receiver to restore the live display.", "·"] : phase === "locked" ? ["Volume locked", "Final value confirmed. Activate again to adjust.", "✓"] : phase === "interrupted" ? ["Session interrupted", "No final lock confirmed. Activate again on the Watch.", "·"] : phase === "live" && stale ? ["Waiting for an update", "Showing the last confirmed value from the receiver.", "·"] : phase === "live" ? lastMovement === "raising" ? ["Volume increasing", "The receiver is accepting higher volume values.", "↑"] : lastMovement === "lowering" ? ["Volume decreasing", "The receiver is accepting lower volume values.", "↓"] : ["Holding steady", "Pause to hold. Single finger touch to lock.", "↕"] : ["Ready when you are", "Wake the Watch and activate Wizardry to get started.", "↕"];
  setText("movement", motion[0]);
  setText("movement-detail", motion[1]);
  setText("motion-icon", motion[2]);
  $("motion-icon").className = `motion-icon${phase === "live" && !stale && online && lastMovement !== "holding" ? " moving" : ""}`;
  for (let i = 1; i <= 3; i++) $("step-" + i).classList.toggle("active", online && i === (phase === "live" ? 2 : phase === "locked" ? 3 : 1));
  setText("count", `${state.accepted} accepted`);
  renderChart(state);
  renderEvents(state.events);
}
function previewState() {
  const now = Date.now() / 1000;
  const elapsed = now - previewStart;
  const cycle = elapsed % 12;
  const curve = (t) => .5 + .24 * Math.sin(Math.min(t, 9) / 9 * Math.PI);
  const start = now - cycle;
  const history = Array.from({length: Math.floor(Math.min(cycle, 9) * 10) + 1}, (_, i) => ({time: start + i / 10, volume: curve(i / 10)}));
  const locked = cycle > 9;
  return {execute: false, phase: locked ? "locked" : "live", serverTime: now, volume: curve(cycle), anchor: .5,
    volumeAt: locked ? start + 9 : now, accepted: history.length + (locked ? 1 : 0), history,
    events: [...(locked ? [{id: 2, time: start + 9, label: "Preview · final volume confirmed", kind: "lock"}] : []), {id: 1, time: start, label: "Preview · live volume started", kind: "volume"}]};
}
$("preview").addEventListener("click", () => {
  preview = !preview;
  previewStart = Date.now() / 1000;
  lastEvents = "";
  lastVolume = null;
  lastVolumeAt = null;
  $("preview-banner").hidden = !preview;
  $("preview").setAttribute("aria-pressed", String(preview));
  $("preview").textContent = preview ? "Return to live display ↗" : "Preview visuals ↗";
});
$("fullscreen").addEventListener("click", async () => {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen();
  } catch { setText("fullscreen", "Full screen unavailable"); }
});
document.addEventListener("fullscreenchange", () => setText("fullscreen", document.fullscreenElement ? "Exit full screen ⛶" : "Full screen ⛶"));
async function poll() {
  if (preview) render(previewState());
  else {
    try {
      const response = await fetch("/status", {cache: "no-store", signal: AbortSignal.timeout(2000)});
      if (!response.ok) throw new Error("Receiver unavailable");
      latest = await response.json();
      render(latest);
    } catch {
      const fallback = latest ?? {execute: null, phase: "waiting", volume: null, anchor: null, volumeAt: null, accepted: 0, events: [], history: []};
      render({...fallback, serverTime: Date.now() / 1000}, false);
    }
  }
  window.setTimeout(poll, document.hidden ? 1000 : 200);
}
poll();

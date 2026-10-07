"use strict";
const $ = (id) => document.getElementById(id);
const route = location.pathname;
const page = route === "/recordings" ? "recordings" : route === "/mappings" ? "mappings" : "sensors";
const titles = {sensors: ["Live sensors", "Every available motion channel, directly from your Watch."], recordings: ["Record movements", "Build a library of examples for training later."], mappings: ["Map movements", "Your familiar actions, with a place for what comes next."]};
$("page-title").textContent = titles[page][0];
$("page-description").textContent = titles[page][1];
document.title = `Wizardry · ${titles[page][0]}`;
for (const name of ["sensors", "recordings", "mappings"]) $(`${name}-page`).hidden = name !== page;
for (const link of document.querySelectorAll(".studio-nav a")) if (link.getAttribute("href") === route) link.setAttribute("aria-current", "page");
let state = null;
let csrf = "";
let cursor = 0;
let samples = [];
let libraryKey = "";
let settingsRevision = "";
let dirtyMapping = false;
let busy = false;
let actionOptionsReady = false;
let createdMovement = null;
const colors = ["#b9a7ff", "#73d2bd", "#eeb685", "#f192b0"];
const groups = [
  {name: "User acceleration", unit: "g", fields: ["ax", "ay", "az"], labels: ["X", "Y", "Z"]},
  {name: "Raw accelerometer", unit: "g", fields: ["rawAx", "rawAy", "rawAz"], labels: ["X", "Y", "Z"]},
  {name: "Rotation rate", unit: "rad/s", fields: ["rx", "ry", "rz"], labels: ["X", "Y", "Z"]},
  {name: "Gravity", unit: "g", fields: ["gx", "gy", "gz"], labels: ["X", "Y", "Z"]},
  {name: "Attitude", unit: "radians", fields: ["roll", "pitch", "yaw"], labels: ["Roll", "Pitch", "Yaw"]},
  {name: "Attitude quaternion", unit: "unitless", fields: ["qx", "qy", "qz", "qw"], labels: ["X", "Y", "Z", "W"]},
  {name: "Magnetic field", unit: "µT", fields: ["mx", "my", "mz"], labels: ["X", "Y", "Z"]},
  {name: "Magnetic accuracy", unit: "−1 uncalibrated · 0 low · 1 medium · 2 high", fields: ["magneticAccuracy"], labels: ["Accuracy"]}
];

function text(id, value) { if ($(id).textContent !== String(value)) $(id).textContent = value; }
function message(value, success = false) { $("studio-message").hidden = !value; text("studio-message", value); $("studio-message").className = `notice${success ? " success" : ""}`; }
function option(value, label) { const el = document.createElement("option"); el.value = value; el.textContent = label; return el; }
function fillSelect(id, values, placeholder = "Choose a movement") {
  const select = $(id), previous = select.value;
  select.replaceChildren(...(values.length ? values.map(([value, label]) => option(value, label)) : [option("", placeholder)]));
  if ([...select.options].some((o) => o.value === previous)) select.value = previous;
}
function currentProfile() { return state?.configuration?.profiles.find((p) => p.id === $("mapping-profile").value); }
function currentBinding() { return currentProfile()?.bindings.find((b) => b.gesture === $("mapping-gesture").value); }
function toggleShortcut(prefix) { $(`${prefix}-shortcut-row`).hidden = $(`${prefix}-action`).value !== "shortcut"; }
function loadBinding() {
  const binding = currentBinding();
  if (!binding) return;
  for (const item of $("mapping-action").querySelectorAll("option[data-existing]")) item.remove();
  if (![...$("mapping-action").options].some((item) => item.value === binding.action)) {
    const existing = option(binding.action, `${state.actions[binding.action]} (existing target)`);
    existing.disabled = true; existing.dataset.existing = "true";
    $("mapping-action").append(existing);
  }
  $("mapping-action").value = binding.action;
  $("mapping-enabled").checked = binding.enabled;
  $("mapping-shortcut").value = binding.shortcutName || "";
  text("mapping-target", binding.targetName ? `Existing target: ${binding.targetName}. Change Home targets on iPhone.` : "Editing mappings does not change your connected target or profile.");
  toggleShortcut("mapping");
  dirtyMapping = false;
}
function loadProfile() {
  const allowed = state.profileActions[$("mapping-profile").value] || [];
  fillSelect("mapping-action", Object.entries(state.actions).filter(([action]) => allowed.includes(action)));
  fillSelect("mapping-gesture", (currentProfile()?.bindings || []).map((b) => [b.gesture, state.gestures[b.gesture]]));
  loadBinding();
}
function loadCustom() {
  const movement = state?.movements.find((m) => m.id === $("custom-movement").value);
  $("custom-action").value = movement?.mapping?.action || "haptic";
  $("custom-shortcut").value = movement?.mapping?.shortcutName || "";
  toggleShortcut("custom");
}

for (const group of groups) {
  const card = document.createElement("article"); card.className = "panel sensor-card";
  const top = document.createElement("div"); top.className = "panel-top";
  const heading = document.createElement("h2"); heading.textContent = group.name;
  const unit = document.createElement("span"); unit.className = "sensor-unit"; unit.textContent = group.unit;
  top.append(heading, unit);
  const canvas = document.createElement("canvas"); canvas.setAttribute("role", "img"); canvas.setAttribute("aria-label", `${group.name} over the last 10 seconds`);
  const empty = document.createElement("p"); empty.className = "sensor-empty"; empty.textContent = "Waiting for live samples";
  const legend = document.createElement("div"); legend.className = "sensor-legend";
  group.values = group.fields.map((field, index) => {
    const row = document.createElement("span"), dot = document.createElement("i"), value = document.createElement("span");
    dot.style.backgroundColor = colors[index]; value.textContent = `${group.labels[index]} —`; row.append(dot, value); legend.append(row); return value;
  });
  card.append(top, canvas, empty, legend); $("sensor-charts").append(card);
  group.canvas = canvas; group.empty = empty;
}

function drawCharts() {
  if (page !== "sensors" || document.hidden) return;
  const newest = samples.at(-1), end = newest?.time || 0;
  const history = samples.filter((sample) => sample.time >= end - 10);
  for (const group of groups) {
    const canvas = group.canvas, ratio = window.devicePixelRatio || 1;
    const width = canvas.clientWidth, height = canvas.clientHeight;
    if (canvas.width !== width * ratio || canvas.height !== height * ratio) { canvas.width = width * ratio; canvas.height = height * ratio; }
    const ctx = canvas.getContext("2d"); ctx.setTransform(ratio, 0, 0, ratio, 0, 0); ctx.clearRect(0, 0, width, height);
    const values = history.flatMap((sample) => group.fields.map((field) => sample[field]).filter(Number.isFinite));
    canvas.classList.toggle("stale", !state || state.stale);
    group.empty.textContent = values.length ? (state.stale ? "Stream stale · showing last received samples" : "Live · 10-second window") : "Not supplied by Watch yet";
    let low = values.length ? Math.min(0, ...values) : -1, high = values.length ? Math.max(0, ...values) : 1;
    if (high - low < .02) { high += .01; low -= .01; }
    const padding = (high - low) * .12; low -= padding; high += padding;
    ctx.font = "10px system-ui"; ctx.fillStyle = "#8d85a1"; ctx.strokeStyle = "#b5a4ff15"; ctx.lineWidth = 1;
    for (let row = 0; row <= 2; row++) {
      const y = 10 + row * (height - 30) / 2;
      ctx.beginPath(); ctx.moveTo(42, y); ctx.lineTo(width, y); ctx.stroke();
      ctx.fillText((high - row * (high - low) / 2).toFixed(2), 0, y + 3);
    }
    for (let index = 0; index < group.fields.length; index++) {
      const field = group.fields[index]; ctx.strokeStyle = colors[index]; ctx.lineWidth = 1.4; ctx.beginPath();
      let previous = null;
      // Only drawing is bounded to screen resolution; recordings keep every frame.
      const stride = Math.max(1, Math.floor(history.length / Math.max(1, width)));
      for (let i = 0; i < history.length; i += stride) {
        const sample = history[i], value = sample[field];
        if (!Number.isFinite(value)) { previous = null; continue; }
        const x = 42 + (sample.time - end + 10) / 10 * (width - 42);
        const y = 10 + (high - value) / (high - low) * (height - 30);
        if (previous === null || sample.time - previous > .08) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        previous = sample.time;
      }
      ctx.stroke();
      group.values[index].textContent = `${group.labels[index]} ${Number.isFinite(newest?.[field]) ? newest[field].toFixed(3) : "—"}`;
    }
  }
}

function renderLibrary() {
  const key = JSON.stringify([state.movements, state.recordings]);
  if (key === libraryKey) return;
  libraryKey = key;
  const movementOptions = state.movements.map((movement) => [movement.id, movement.name]);
  fillSelect("recording-movement", movementOptions, "Create a movement first");
  fillSelect("custom-movement", movementOptions, "Create a movement on Record movements");
  if (createdMovement && state.movements.some((movement) => movement.id === createdMovement)) {
    $("recording-movement").value = createdMovement;
    $("custom-movement").value = createdMovement;
    createdMovement = null;
  }
  loadCustom();
  text("movement-count", `${state.movements.length} saved`);
  renderRecordings();
}
function renderRecordings() {
  const records = state.recordings.filter((recording) => !$("recording-movement").value || recording.movementID === $("recording-movement").value).slice().reverse();
  text("recording-count", `${records.length} ${records.length === 1 ? "recording" : "recordings"}`);
  $("recording-list").replaceChildren();
  if (!records.length) { const empty = document.createElement("p"); empty.className = "empty-state"; empty.textContent = "No examples saved for this movement yet. Record a short, deliberate movement, then repeat it a few times."; $("recording-list").append(empty); }
  records.forEach((recording, index) => {
    const row = document.createElement("article"); row.className = "recording-row";
    const title = document.createElement("h3"); title.textContent = `${recording.movementName} · Example ${records.length - index}`;
    const quality = document.createElement("span"); quality.className = `recording-quality${recording.partial ? " partial" : ""}`; quality.textContent = recording.partial ? "Partial · review before training" : "Captured";
    const detail = document.createElement("p"); detail.textContent = `${recording.duration.toFixed(2)}s · ${recording.sampleCount} samples · ${recording.measuredHz.toFixed(1)} Hz · ${new Date(recording.startedAt * 1000).toLocaleString()}`;
    const issues = document.createElement("p"); issues.textContent = recording.issues.join(" · ");
    const download = document.createElement("a"); download.href = `/api/recordings/${encodeURIComponent(recording.id)}.json`; download.textContent = "Download original samples ↓"; download.download = `wizardry-${recording.id}.json`;
    row.append(title, quality, detail, issues, download); $("recording-list").append(row);
  });
}

function render() {
  const active = state.activeRecording;
  text("studio-connection-label", state.phoneConnected ? "iPhone connected" : "Waiting for iPhone");
  $("studio-connection").classList.toggle("offline", !state.phoneConnected);
  text("stream-badge", active ? active.ready ? "RECORDING · ACTIONS PAUSED" : "PREPARING RECORDING" : state.telemetryRequested ? state.stale ? "WAITING FOR FRESH SAMPLES" : "LIVE MOTION" : "STREAM STOPPED");
  text("stream-detail", !state.phoneConnected ? "On iPhone, connect the computer receiver and enable Computer studio. Keep both apps open." : !state.telemetryRequested ? "iPhone linked. Start sensors to view your Watch motion. Your selected control target stays unchanged." : state.stale ? "Waiting for fresh Watch samples. Keep Wizardry open on Watch and iPhone." : "Watch motion is arriving through your iPhone. Your selected control target stays unchanged.");
  $("start-stream").disabled = busy || state.streamEnabled;
  $("stop-stream").disabled = busy || !state.streamEnabled || !!active;
  const recent = samples.filter((sample) => sample.time >= (samples.at(-1)?.time || 0) - 2);
  const span = recent.length > 1 ? recent.at(-1).time - recent[0].time : 0;
  text("sample-rate", state.stale || !span ? "—" : `${((recent.length - 1) / span).toFixed(1)} Hz`);
  text("last-sample", state.lastSampleAt === null ? "—" : state.stale ? `${Math.max(0, state.serverTime - state.lastSampleAt).toFixed(1)}s ago` : "Live");
  text("missing-batches", state.batchGaps); text("dropped-samples", state.droppedSamples);
  text("sensor-origin", [state.metadata.watchModel, state.metadata.watchOS && `watchOS ${state.metadata.watchOS}`, state.metadata.requestedSampleHz && `${state.metadata.requestedSampleHz} Hz requested`].filter(Boolean).join(" · ") || "Waiting for Watch metadata");
  renderLibrary();
  if (!actionOptionsReady) {
    const actions = Object.entries(state.actions).filter(([action]) => !["lightOn", "lightOff", "lightToggle", "homeScene"].includes(action));
    fillSelect("mapping-action", actions); fillSelect("custom-action", actions); actionOptionsReady = true;
    loadCustom();
  }
  if (state.configuration && state.configuration.revision !== settingsRevision && !dirtyMapping) {
    settingsRevision = state.configuration.revision;
    fillSelect("mapping-profile", state.configuration.profiles.filter((p) => ["computer", "phone"].includes(p.id)).map((p) => [p.id, p.name]));
    loadProfile();
  }
  $("recording-movement").disabled = !!active;
  $("record-start").disabled = busy || !!active || state.captureSettling || state.stale || !state.telemetryRequested || !$("recording-movement").value;
  $("record-stop").disabled = busy || !active; $("record-cancel").disabled = busy || !active;
  $("recording-dot").classList.toggle("active", !!active?.ready);
  text("recording-status", active ? active.ready ? "Recording — move now" : "Preparing — hold still" : state.captureSettling ? "Finishing capture on Watch" : "Ready to record");
  text("recording-time", active ? `${Math.ceil(active.secondsRemaining)}s remaining · ${active.sampleCount} samples` : "Up to 60 seconds");
  text("recording-detail", active ? active.ready ? "Actions are paused on Watch. Stop & save when your movement is complete." : "Waiting for Watch to confirm capture mode. Begin only when this says Recording." : "Start sensors and wait for live samples. During recording, Watch gestures are captured for the library; actions are paused.");
  $("mapping-save").disabled = busy || !state.phoneConnected || state.mappingPending || !currentBinding();
  $("custom-save").disabled = busy || !$("custom-movement").value;
  text("mapping-status", state.mappingStatus);
  if (state.loadError) message(state.loadError);
}

async function post(operation, payload = {}) {
  if (busy) return null;
  busy = true; if (state) render(); message("");
  try {
    const response = await fetch(`/api/${operation}`, {method: "POST", headers: {"Content-Type": "application/json", "X-Wizardry-CSRF": csrf}, body: JSON.stringify(payload), signal: AbortSignal.timeout(5000)});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Operation failed");
    return result;
  } catch (error) { message(error.message || "Receiver unavailable. No automatic retry was sent."); return null; }
  finally { busy = false; if (state) render(); }
}

$("start-stream").addEventListener("click", () => post("stream/start"));
$("stop-stream").addEventListener("click", () => post("stream/stop"));
$("movement-form").addEventListener("submit", async (event) => { event.preventDefault(); const result = await post("movements/create", {name: $("movement-name").value}); if (result) { createdMovement = result.movement.id; $("movement-name").value = ""; message(`Created ${result.movement.name}. Start sensors, then record an example.`, true); } });
$("recording-movement").addEventListener("change", renderRecordings);
$("record-start").addEventListener("click", () => post("recordings/start", {movementID: $("recording-movement").value}));
$("record-stop").addEventListener("click", async () => { const result = await post("recordings/stop"); if (result) message(result.recording.partial ? "Saved a partial recording. Review the listed gaps before future training." : "Recording saved. Record another example when ready.", !result.recording.partial); });
$("record-cancel").addEventListener("click", async () => { if (await post("recordings/cancel")) message("Recording cancelled. No example was saved.", true); });
$("mapping-profile").addEventListener("change", loadProfile);
$("mapping-gesture").addEventListener("change", loadBinding);
$("mapping-action").addEventListener("change", () => { dirtyMapping = true; toggleShortcut("mapping"); });
$("mapping-enabled").addEventListener("change", () => { dirtyMapping = true; });
$("mapping-shortcut").addEventListener("input", () => { dirtyMapping = true; });
$("custom-movement").addEventListener("change", loadCustom);
$("custom-action").addEventListener("change", () => toggleShortcut("custom"));
$("builtin-form").addEventListener("submit", async (event) => {
  event.preventDefault(); const existing = currentBinding(); if (!existing) return;
  const action = $("mapping-action").value;
  const binding = {...existing, action, enabled: $("mapping-enabled").checked, shortcutName: action === "shortcut" ? $("mapping-shortcut").value : ""};
  if (!["lightOn", "lightOff", "lightToggle", "homeScene"].includes(action)) {
    binding.targetID = ""; binding.homeID = ""; binding.targetName = "";
  }
  const result = await post("mappings/builtin", {revision: settingsRevision, profileID: $("mapping-profile").value, binding});
  if (result) { dirtyMapping = false; message("Mapping sent to iPhone. Watch the sync status for confirmation.", true); }
});
$("custom-form").addEventListener("submit", async (event) => {
  event.preventDefault(); const action = $("custom-action").value;
  const result = await post("mappings/custom", {movementID: $("custom-movement").value, binding: {action, enabled: false, shortcutName: action === "shortcut" ? $("custom-shortcut").value : ""}});
  if (result) message("Planned mapping saved locally. This movement remains untrained and inactive.", true);
});

async function poll() {
  try {
    const response = await fetch(`/api/studio?after=${cursor}`, {cache: "no-store", signal: AbortSignal.timeout(2000)});
    if (!response.ok) throw new Error("Receiver unavailable");
    state = await response.json(); csrf = state.csrfToken;
    if (state.cursor < cursor) { cursor = 0; samples = []; settingsRevision = ""; }
    for (const sample of state.samples) {
      if (sample.cursor <= cursor) continue;
      if (samples.length && sample.time < samples.at(-1).time) samples = [];
      samples.push(sample);
    }
    cursor = state.cursor;
    if (samples.length > 1500) samples.splice(0, samples.length - 1500);
    render();
  } catch {
    text("studio-connection-label", "Receiver unavailable"); $("studio-connection").classList.add("offline");
    text("stream-badge", "OFFLINE · LAST RECEIVED VALUES");
    if (state) state.stale = true;
    for (const id of ["start-stream", "stop-stream", "record-start", "record-stop", "record-cancel", "mapping-save", "custom-save"]) $(id).disabled = true;
  }
  window.setTimeout(poll, document.hidden ? 1000 : page === "sensors" ? 100 : 250);
}
window.setInterval(drawCharts, 50);
poll();

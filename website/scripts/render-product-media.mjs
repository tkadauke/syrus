import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const publicDir = path.join(process.cwd(), "public");
const mediaDir = path.join(publicDir, "media");
fs.mkdirSync(mediaDir, { recursive: true });

const colors = {
  ink: "#14110d",
  panel: "#1b1712",
  panel2: "#221c16",
  cream: "#ece3d4",
  dim: "#b3a793",
  faint: "#8a7f6d",
  clay: "#cd7a5c",
  clayBright: "#dba28b",
  clayDeep: "#b6492e",
  green: "#77bd83",
  blue: "#7fa8dc",
  yellow: "#d5b45f",
  red: "#ee8067",
};

const esc = (value) =>
  String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

function svgShell({ title, subtitle, active = "Dashboard", body }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000" viewBox="0 0 1600 1000">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#2b211a"/>
      <stop offset="0.48" stop-color="#14110d"/>
      <stop offset="1" stop-color="#24140d"/>
    </linearGradient>
    <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="${colors.clayBright}"/>
      <stop offset="0.58" stop-color="${colors.clay}"/>
      <stop offset="1" stop-color="${colors.clayDeep}"/>
    </linearGradient>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">
      <feDropShadow dx="0" dy="34" stdDeviation="42" flood-color="#000" flood-opacity="0.42"/>
    </filter>
    <filter id="soft" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="80"/>
    </filter>
    <style>
      text { font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
      .mono { font-family: "JetBrains Mono", "SF Mono", Menlo, monospace; }
      .title { fill: ${colors.cream}; font-size: 44px; font-weight: 720; letter-spacing: 0; }
      .body { fill: ${colors.dim}; font-size: 24px; font-weight: 430; }
      .small { fill: ${colors.faint}; font-size: 18px; font-weight: 520; }
      .label { fill: ${colors.dim}; font-size: 16px; font-weight: 700; text-transform: uppercase; letter-spacing: 2px; }
      .nav { fill: ${colors.dim}; font-size: 19px; font-weight: 620; }
      .navActive { fill: ${colors.cream}; font-size: 19px; font-weight: 720; }
      .chip { fill: ${colors.cream}; font-size: 18px; font-weight: 650; }
      .metric { fill: ${colors.cream}; font-size: 36px; font-weight: 730; }
    </style>
  </defs>
  <rect width="1600" height="1000" fill="url(#bg)"/>
  <circle cx="1220" cy="80" r="240" fill="${colors.clayDeep}" opacity="0.18" filter="url(#soft)"/>
  <circle cx="240" cy="810" r="300" fill="${colors.clay}" opacity="0.13" filter="url(#soft)"/>
  <rect x="72" y="56" width="1456" height="888" rx="32" fill="${colors.panel}" stroke="#ffffff" stroke-opacity="0.08" filter="url(#shadow)"/>
  <rect x="72" y="56" width="1456" height="74" rx="32" fill="#18130f"/>
  <path d="M72 98h1456v32H72z" fill="#18130f"/>
  <circle cx="116" cy="92" r="8" fill="#f0806a"/>
  <circle cx="146" cy="92" r="8" fill="#d5b45f"/>
  <circle cx="176" cy="92" r="8" fill="#77bd83"/>
  <text x="220" y="99" class="mono small">syrus.local</text>
  <rect x="112" y="166" width="244" height="720" rx="22" fill="#15110d" stroke="#ffffff" stroke-opacity="0.07"/>
  <text x="146" y="218" fill="${colors.cream}" font-size="28" font-weight="760">Syrus</text>
  ${["Dashboard", "Chat", "Jobs", "Epics", "Merge queue", "Spending", "Settings"]
    .map((item, index) => {
      const y = 274 + index * 62;
      const selected = item === active;
      return selected
        ? `<rect x="132" y="${y - 28}" width="196" height="44" rx="12" fill="${colors.clay}" opacity="0.18"/><text x="154" y="${y}" class="navActive">${esc(item)}</text>`
        : `<text x="154" y="${y}" class="nav">${esc(item)}</text>`;
    })
    .join("")}
  <rect x="132" y="800" width="196" height="52" rx="16" fill="#ffffff" opacity="0.035" stroke="#ffffff" stroke-opacity="0.07"/>
  <circle cx="164" cy="826" r="12" fill="url(#accent)"/>
  <text x="188" y="833" class="small">3 agents active</text>
  <text x="404" y="218" class="title">${esc(title)}</text>
  <text x="404" y="258" class="body">${esc(subtitle)}</text>
  ${body}
</svg>`;
}

function pill(x, y, text, color = colors.clay) {
  const width = text.length * 10 + 38;
  return `<rect x="${x}" y="${y}" width="${width}" height="34" rx="17" fill="${color}" opacity="0.16" stroke="${color}" stroke-opacity="0.45"/><text x="${x + 19}" y="${y + 23}" class="mono" fill="${colors.cream}" font-size="15" font-weight="700">${esc(text)}</text>`;
}

function row({ x, y, w = 1000, title, meta, status, statusColor, progress = 0.62 }) {
  return `
  <rect x="${x}" y="${y}" width="${w}" height="92" rx="18" fill="#ffffff" opacity="0.035" stroke="#ffffff" stroke-opacity="0.07"/>
  <circle cx="${x + 34}" cy="${y + 46}" r="8" fill="${statusColor}"/>
  <text x="${x + 60}" y="${y + 39}" fill="${colors.cream}" font-size="22" font-weight="700">${esc(title)}</text>
  <text x="${x + 60}" y="${y + 66}" class="mono small">${esc(meta)}</text>
  <rect x="${x + w - 206}" y="${y + 24}" width="150" height="34" rx="17" fill="${statusColor}" opacity="0.15" stroke="${statusColor}" stroke-opacity="0.5"/>
  <text x="${x + w - 186}" y="${y + 47}" class="mono" fill="${colors.cream}" font-size="14" font-weight="700">${esc(status)}</text>
  <rect x="${x + 60}" y="${y + 76}" width="360" height="5" rx="3" fill="#ffffff" opacity="0.08"/>
  <rect x="${x + 60}" y="${y + 76}" width="${Math.round(360 * progress)}" height="5" rx="3" fill="${statusColor}"/>`;
}

function dashboard() {
  return svgShell({
    title: "Roadmap work, in flight",
    subtitle: "Issues, chat goals, reviews, and scheduled work converge into tracked Jobs.",
    active: "Dashboard",
    body: `
      <g transform="translate(404 308)">
        ${[
          ["Open Jobs", "18", colors.clay],
          ["PRs opened", "11", colors.blue],
          ["Landing queue", "4", colors.green],
          ["Spend today", "$42.18", colors.yellow],
        ]
          .map(
            ([label, value, color], i) => `
        <rect x="${i * 248}" y="0" width="220" height="132" rx="20" fill="#ffffff" opacity="0.04" stroke="#ffffff" stroke-opacity="0.08"/>
        <text x="${i * 248 + 22}" y="42" class="label">${esc(label)}</text>
        <text x="${i * 248 + 22}" y="91" class="metric">${esc(value)}</text>
        <circle cx="${i * 248 + 184}" cy="46" r="13" fill="${color}" opacity="0.78"/>`,
          )
          .join("")}
      </g>
      ${row({ x: 404, y: 500, w: 760, title: "Implement video walkthrough proposals", meta: "Codex · implementation step · checks running", status: "Running", statusColor: colors.clay, progress: 0.78 })}
      ${row({ x: 404, y: 612, w: 760, title: "Repair failing release smoke test", meta: "Claude Code · PR opened · human review next", status: "PR open", statusColor: colors.blue, progress: 0.92 })}
      ${row({ x: 404, y: 724, w: 760, title: "Land stacked settings refresh", meta: "Merge train · dependency order preserved", status: "Landing", statusColor: colors.green, progress: 0.58 })}
      <rect x="1224" y="500" width="232" height="316" rx="22" fill="#ffffff" opacity="0.035" stroke="#ffffff" stroke-opacity="0.07"/>
      <text x="1252" y="548" class="label">Worker health</text>
      <circle cx="1340" cy="660" r="76" fill="none" stroke="#ffffff" stroke-opacity="0.08" stroke-width="18"/>
      <path d="M1340 584a76 76 0 1 1-70 106" fill="none" stroke="${colors.green}" stroke-width="18" stroke-linecap="round"/>
      <text x="1302" y="672" class="metric">87%</text>
      <text x="1252" y="770" class="small">Queue moving · no blocked work</text>`,
  });
}

function walkthrough() {
  return svgShell({
    title: "A narrated screen recording becomes work",
    subtitle: "Syrus reads the video, pulls out the repro, and proposes the Job before code starts.",
    active: "Chat",
    body: `
      <rect x="404" y="314" width="640" height="472" rx="24" fill="#10100f" stroke="#ffffff" stroke-opacity="0.08"/>
      <rect x="436" y="352" width="576" height="324" rx="18" fill="#27211b"/>
      <rect x="466" y="388" width="248" height="54" rx="12" fill="#ffffff" opacity="0.08"/>
      <rect x="466" y="462" width="494" height="36" rx="10" fill="#ffffff" opacity="0.06"/>
      <rect x="466" y="518" width="408" height="36" rx="10" fill="#ffffff" opacity="0.06"/>
      <path d="M754 448l122 70-122 70z" fill="url(#accent)"/>
      <rect x="436" y="706" width="576" height="38" rx="19" fill="#ffffff" opacity="0.07"/>
      <rect x="436" y="706" width="390" height="38" rx="19" fill="url(#accent)"/>
      <text x="458" y="730" class="mono" fill="#3a1308" font-size="15" font-weight="760">01:14 / 01:48 · screen + microphone</text>
      <rect x="1084" y="314" width="372" height="472" rx="24" fill="#ffffff" opacity="0.035" stroke="#ffffff" stroke-opacity="0.08"/>
      <text x="1118" y="366" class="label">Extracted from video</text>
      ${pill(1118, 400, "bug: empty table")}
      ${pill(1118, 452, "expected: live rows", colors.blue)}
      ${pill(1118, 504, "route: /insights/spending", colors.green)}
      <line x1="1118" y1="596" x2="1424" y2="596" stroke="#ffffff" stroke-opacity="0.08"/>
      <text x="1118" y="642" fill="${colors.cream}" font-size="24" font-weight="720">Draft Job ready</text>
      <text x="1118" y="682" class="body">Fix spending table empty state, add</text>
      <text x="1118" y="714" class="body">coverage, open a reviewed PR.</text>`,
  });
}

function graph() {
  return svgShell({
    title: "Epics keep dependent work ordered",
    subtitle: "Parallel Jobs move independently, then the merge train lands the stack in sequence.",
    active: "Epics",
    body: `
      <rect x="404" y="324" width="660" height="462" rx="24" fill="#ffffff" opacity="0.035" stroke="#ffffff" stroke-opacity="0.08"/>
      <path d="M538 462 C650 462 650 356 760 356" stroke="${colors.clay}" stroke-width="5" fill="none" opacity="0.75"/>
      <path d="M538 462 C650 462 650 568 760 568" stroke="${colors.clay}" stroke-width="5" fill="none" opacity="0.75"/>
      <path d="M904 356 C968 356 980 462 1000 462" stroke="${colors.green}" stroke-width="5" fill="none" opacity="0.75"/>
      <path d="M904 568 C968 568 980 462 1000 462" stroke="${colors.green}" stroke-width="5" fill="none" opacity="0.75"/>
      ${node(466, 422, "Plan", "confirmed", colors.clay)}
      ${node(760, 316, "Backend", "PR ready", colors.blue)}
      ${node(760, 528, "Frontend", "checks pass", colors.blue)}
      ${node(940, 422, "Landing", "queued", colors.green)}
      <rect x="1110" y="324" width="346" height="462" rx="24" fill="#ffffff" opacity="0.035" stroke="#ffffff" stroke-opacity="0.08"/>
      <text x="1144" y="374" class="label">Merge train</text>
      ${trainRow(1144, 424, "1", "backend primitives", colors.green)}
      ${trainRow(1144, 500, "2", "UI + copy", colors.clay)}
      ${trainRow(1144, 576, "3", "docs refresh", colors.yellow)}
      <text x="1144" y="706" class="body">Each branch is rechecked</text>
      <text x="1144" y="738" class="body">against the exact code it lands on.</text>`,
  });
}

function node(x, y, title, meta, color) {
  return `<rect x="${x}" y="${y}" width="144" height="80" rx="18" fill="${color}" opacity="0.17" stroke="${color}" stroke-opacity="0.52"/><text x="${x + 22}" y="${y + 34}" fill="${colors.cream}" font-size="20" font-weight="720">${esc(title)}</text><text x="${x + 22}" y="${y + 60}" class="mono" fill="${colors.dim}" font-size="14">${esc(meta)}</text>`;
}

function trainRow(x, y, index, label, color) {
  return `<circle cx="${x + 18}" cy="${y + 22}" r="18" fill="${color}" opacity="0.22" stroke="${color}" stroke-opacity="0.6"/><text x="${x + 12}" y="${y + 29}" fill="${colors.cream}" font-size="18" font-weight="720">${index}</text><text x="${x + 54}" y="${y + 29}" fill="${colors.cream}" font-size="20" font-weight="650">${esc(label)}</text>`;
}

function spending() {
  const bars = [132, 216, 172, 258, 198, 304, 236];
  return svgShell({
    title: "Spend stays visible",
    subtitle: "Runs roll up by repository, epic, user, provider, and time window.",
    active: "Spending",
    body: `
      <g transform="translate(404 316)">
        <rect width="680" height="470" rx="24" fill="#ffffff" opacity="0.035" stroke="#ffffff" stroke-opacity="0.08"/>
        <text x="34" y="58" class="label">Cost trend</text>
        ${bars
          .map(
            (h, i) =>
              `<rect x="${64 + i * 82}" y="${392 - h}" width="44" height="${h}" rx="12" fill="${i === 5 ? colors.clay : colors.blue}" opacity="${i === 5 ? 0.9 : 0.42}"/>`,
          )
          .join("")}
        <line x1="44" y1="392" x2="620" y2="392" stroke="#ffffff" stroke-opacity="0.1"/>
        <text x="34" y="446" class="small">Last 7 days · $318.72 total</text>
      </g>
      <g transform="translate(1120 316)">
        <rect width="336" height="470" rx="24" fill="#ffffff" opacity="0.035" stroke="#ffffff" stroke-opacity="0.08"/>
        <text x="30" y="58" class="label">Top spend</text>
      ${spendLine(30, 110, "Walkthroughs", "$92.11", colors.clay)}
        ${spendLine(30, 178, "Release repairs", "$74.20", colors.blue)}
        ${spendLine(30, 246, "Docs sweep", "$39.84", colors.green)}
        <line x1="30" y1="318" x2="306" y2="318" stroke="#ffffff" stroke-opacity="0.08"/>
        <text x="30" y="370" class="body">Every Job keeps the</text>
        <text x="30" y="402" class="body">transcript, diff, and</text>
        <text x="30" y="434" class="body">model cost together.</text>
      </g>`,
  });
}

function spendLine(x, y, label, amount, color) {
  return `<circle cx="${x + 12}" cy="${y}" r="8" fill="${color}"/><text x="${x + 32}" y="${y + 7}" fill="${colors.cream}" font-size="20" font-weight="650">${esc(label)}</text><text x="${x + 236}" y="${y + 7}" class="mono" fill="${colors.dim}" font-size="17">${esc(amount)}</text>`;
}

function mobile() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="471" height="1024" viewBox="0 0 471 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#221c16"/><stop offset="1" stop-color="#14110d"/>
    </linearGradient>
    <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="${colors.clayBright}"/><stop offset="1" stop-color="${colors.clayDeep}"/>
    </linearGradient>
    <style>
      text { font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
      .mono { font-family: "JetBrains Mono", "SF Mono", Menlo, monospace; }
    </style>
  </defs>
  <rect width="471" height="1024" fill="url(#bg)"/>
  <text x="34" y="76" fill="${colors.cream}" font-size="28" font-weight="760">Syrus</text>
  <circle cx="424" cy="64" r="14" fill="url(#accent)"/>
  <text x="34" y="140" fill="${colors.cream}" font-size="32" font-weight="760">Active Jobs</text>
  <text x="34" y="178" fill="${colors.dim}" font-size="18">Walkthroughs, reviews, and landing queue.</text>
  ${mobileCard(34, 224, "Walkthrough to Job", "Video analyzed · proposal ready", "Ready", colors.clay)}
  ${mobileCard(34, 372, "Fix release smoke test", "PR opened · waiting for review", "Review", colors.blue)}
  ${mobileCard(34, 520, "Land settings refresh", "Merge train · checks running", "Landing", colors.green)}
  <rect x="34" y="708" width="403" height="220" rx="26" fill="#ffffff" opacity="0.045" stroke="#ffffff" stroke-opacity="0.08"/>
  <text x="64" y="762" fill="${colors.dim}" font-size="16" font-weight="700">TODAY</text>
  <text x="64" y="824" fill="${colors.cream}" font-size="48" font-weight="780">$42.18</text>
  <text x="64" y="868" fill="${colors.dim}" font-size="19">4 Jobs completed · 2 PRs landed</text>
  <rect x="64" y="892" width="300" height="8" rx="4" fill="#ffffff" opacity="0.09"/>
  <rect x="64" y="892" width="218" height="8" rx="4" fill="url(#accent)"/>
</svg>`;
}

function mobileCard(x, y, title, meta, status, color) {
  return `<rect x="${x}" y="${y}" width="403" height="116" rx="24" fill="#ffffff" opacity="0.045" stroke="#ffffff" stroke-opacity="0.08"/><circle cx="${x + 30}" cy="${y + 38}" r="8" fill="${color}"/><text x="${x + 54}" y="${y + 43}" fill="${colors.cream}" font-size="20" font-weight="720">${esc(title)}</text><text x="${x + 54}" y="${y + 76}" fill="${colors.dim}" font-size="16">${esc(meta)}</text><rect x="${x + 286}" y="${y + 72}" width="82" height="28" rx="14" fill="${color}" opacity="0.18"/><text x="${x + 306}" y="${y + 91}" fill="${colors.cream}" font-size="13" font-weight="740">${esc(status)}</text>`;
}

function og() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2b211a"/><stop offset="0.55" stop-color="#14110d"/><stop offset="1" stop-color="#2a160e"/></linearGradient>
    <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="${colors.clayBright}"/><stop offset="0.55" stop-color="${colors.clay}"/><stop offset="1" stop-color="${colors.clayDeep}"/></linearGradient>
    <filter id="shadow"><feDropShadow dx="0" dy="28" stdDeviation="28" flood-color="#000" flood-opacity="0.45"/></filter>
    <style>text{font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.mono{font-family:"JetBrains Mono","SF Mono",Menlo,monospace}</style>
  </defs>
  <rect width="1200" height="630" fill="url(#bg)"/>
  <circle cx="990" cy="82" r="200" fill="${colors.clay}" opacity="0.18"/>
  <text x="84" y="132" fill="${colors.cream}" font-size="54" font-weight="790">Syrus</text>
  <text x="84" y="222" fill="${colors.cream}" font-size="48" font-weight="780">Screen recordings</text>
  <text x="84" y="282" fill="${colors.clayBright}" font-size="48" font-weight="780">become reviewed PRs.</text>
  <text x="84" y="366" fill="${colors.dim}" font-size="25">Self-hosted issue-to-PR automation</text>
  <text x="84" y="402" fill="${colors.dim}" font-size="25">with tracked Jobs and cost visibility.</text>
  <rect x="750" y="174" width="346" height="280" rx="28" fill="${colors.panel}" stroke="#ffffff" stroke-opacity="0.1" filter="url(#shadow)"/>
  <rect x="782" y="214" width="282" height="156" rx="18" fill="#2b211a"/>
  <path d="M900 256l76 43-76 44z" fill="url(#accent)"/>
  <rect x="782" y="396" width="224" height="34" rx="17" fill="url(#accent)"/>
  <text x="810" y="418" class="mono" fill="#351207" font-size="14" font-weight="780">video analyzed</text>
  <rect x="84" y="494" width="244" height="48" rx="24" fill="url(#accent)"/>
  <text x="112" y="526" fill="#351207" font-size="20" font-weight="780">95.1% self-built</text>
</svg>`;
}

function renderPng({ name, svg, size, root = publicDir }) {
  const svgPath = path.join(root, `${name}.svg`);
  const pngPath = path.join(root, `${name}.png`);
  fs.writeFileSync(svgPath, svg);
  execFileSync("ffmpeg", [
    "-y",
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "svg_pipe",
    "-i",
    svgPath,
    "-vf",
    `scale=${size.replace("x", ":")}:flags=lanczos,format=rgba`,
    "-frames:v",
    "1",
    pngPath,
  ]);
  fs.rmSync(svgPath);
  return pngPath;
}

const stillAssets = [
  ["product-screenshot", dashboard(), "1600x1000"],
  ["product-screenshot-mobile", mobile(), "471x1024"],
  ["media/walkthrough-recording", walkthrough(), "1600x1000"],
  ["media/epic-merge-train", graph(), "1600x1000"],
  ["media/spending-audit", spending(), "1600x1000"],
  ["og", og(), "1200x630"],
];

for (const [name, svg, size] of stillAssets) {
  renderPng({ name, svg, size });
}

const tempDir = path.join(process.cwd(), ".product-media-render");
fs.rmSync(tempDir, { recursive: true, force: true });
fs.mkdirSync(tempDir, { recursive: true });

const frameAssets = [
  ["screencast-frame-01", walkthrough(), "1600x1000", 2.4],
  ["screencast-frame-02", dashboard(), "1600x1000", 2.1],
  ["screencast-frame-03", graph(), "1600x1000", 2.1],
  ["screencast-frame-04", spending(), "1600x1000", 2.3],
];

for (const [name, svg, size] of frameAssets) {
  renderPng({ name, svg, size, root: tempDir });
}

const frameList = path.join(tempDir, "screencast-frames.txt");
fs.writeFileSync(
  frameList,
  [
    ...frameAssets.flatMap(([name, , , duration]) => [
      `file '${path.join(tempDir, `${name}.png`)}'`,
      `duration ${duration}`,
    ]),
    `file '${path.join(tempDir, "screencast-frame-04.png")}'`,
  ].join("\n"),
);

execFileSync("ffmpeg", [
  "-y",
  "-hide_banner",
  "-loglevel",
  "error",
  "-f",
  "concat",
  "-safe",
  "0",
  "-i",
  frameList,
  "-vf",
  "fps=30,format=yuv420p",
  "-c:v",
  "libx264",
  "-movflags",
  "+faststart",
  path.join(mediaDir, "syrus-product-screencast.mp4"),
]);

execFileSync("ffmpeg", [
  "-y",
  "-hide_banner",
  "-loglevel",
  "error",
  "-f",
  "concat",
  "-safe",
  "0",
  "-i",
  frameList,
  "-vf",
  "fps=30,format=yuv420p",
  "-c:v",
  "libvpx-vp9",
  "-b:v",
  "0",
  "-crf",
  "35",
  path.join(mediaDir, "syrus-product-screencast.webm"),
]);

fs.writeFileSync(
  path.join(mediaDir, "syrus-product-screencast.vtt"),
  `WEBVTT

00:00.000 --> 00:02.400
A narrated screen recording is attached in Syrus chat.

00:02.400 --> 00:04.500
Syrus analyzes the video and turns the repro into a tracked Job.

00:04.500 --> 00:06.600
Related Jobs stay ordered through epics and the merge train.

00:06.600 --> 00:08.900
Every run keeps its transcript, diff, and model cost visible.
`,
);

for (const old of ["product-screenshot.jpeg", "product-screenshot-mobile.jpeg"]) {
  const file = path.join(publicDir, old);
  if (fs.existsSync(file)) fs.rmSync(file);
}

fs.rmSync(tempDir, { recursive: true, force: true });

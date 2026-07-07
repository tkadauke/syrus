// Finder-layout hook for the DMG target, wired via `artifactBuildStarted` in
// electron-builder.yml. It fixes two things electron-builder's config schema
// cannot express:
//
// 1. Dev-unique volume names. Finder caches icon-view window geometry per
//    VOLUME NAME, so successive dev builds that all mount as "Syrus 0.0.0"
//    reuse stale (possibly user-mangled) window geometry — the shipped
//    too-small-window-with-scrollbar bug. Release builds self-heal because
//    each version mounts under a fresh name ("Syrus 0.1.2"), so when
//    SYRUS_RELEASE_BUILD=1 (set by .github/workflows/release.yml) the
//    canonical `dmg.title` name is kept. Everything else is a dev build and
//    gets a "(<short-sha>-<hhmmss>)" suffix so every mount starts from the
//    .DS_Store geometry, never from a Finder cache.
//
// 2. Off-window icon positions for the helper files dmgbuild writes into the
//    volume root: .background.tiff, .VolumeIcon.icns, and .DS_Store. They are
//    dot-invisible for most users, but anyone with "show hidden files" on
//    sees them auto-arranged INSIDE the visible window (and their icons
//    extend the scroll extent, producing scrollbars). dmgbuild's settings
//    JSON natively supports `type: "position"` contents entries — an
//    icon-location record for a NAME, with no file copied — but
//    electron-builder's schema only allows dir|file|link, so the entries
//    can't be declared in electron-builder.yml. This hook wraps dmg-builder's
//    customizeDmg and appends them after schema validation has already run;
//    dmgUtil forwards contents entries (path/x/y/name/type) verbatim into the
//    dmgbuild settings JSON, and dmgbuild writes one Iloc record per entry.
//
//    (The documented CUSTOM_DMGBUILD_PATH escape hatch was considered
//    instead, but setting it stops electron-builder from downloading the
//    stock dmgbuild bundle at all, which breaks fresh CI machines, and it
//    still couldn't rewrite the volume name passed on dmgbuild's argv.)
//
// Verified against electron-builder/dmg-builder 26.15.6 (dmgbuild bundle
// 75c8a6c). The hook is SELF-VALIDATING at build time: it re-checks every
// dmg-builder seam it relies on and THROWS — failing the DMG build loudly —
// when one has drifted, because spec/desktop/packaging_spec.rb's equivalent
// node_modules-gated check skips wherever desktop deps aren't installed
// (every CI pipeline). A silently-default-layout DMG is the exact failure
// this hook exists to prevent, so no validation path warns-and-continues.
"use strict";

const { execSync } = require("node:child_process");
const fs = require("node:fs");

const fail = detail => {
  throw new Error(
    `dmg-finder-layout: ${detail} — most likely electron-builder/dmg-builder ` +
      "version drift (this hook was verified against dmg-builder 26.15.6). " +
      "Re-verify the seams and update scripts/dmg-finder-layout.cjs and " +
      "spec/desktop/packaging_spec.rb together."
  );
};

// Center coordinates for the helper-file icons, in background-image points.
// The visible design is 660x400 (the 1x page of build/dmg-background.tiff —
// see scripts/render-dmg-background.mjs); rows at y >= 600 sit safely below
// it. Keeping x within the 660pt width means show-hidden-files users get at
// most a vertical scroll extent, never a horizontal one.
const HELPER_ICON_POSITIONS = {
  ".background.tiff": { x: 132, y: 600 },
  ".VolumeIcon.icns": { x: 330, y: 600 },
  ".DS_Store": { x: 528, y: 600 },
  // Not normally present (dmgbuild removes .Trashes and the final image is
  // read-only), but cheap insurance in case a build host's fseventsd writes
  // into the read-write staging image. An Iloc record for a missing name is
  // inert.
  ".fseventsd": { x: 330, y: 780 },
};

const devVolumeNameSuffix = () => {
  const now = new Date();
  const hhmmss = [now.getHours(), now.getMinutes(), now.getSeconds()]
    .map(part => String(part).padStart(2, "0"))
    .join("");
  let sha = "";
  try {
    sha = execSync("git rev-parse --short HEAD", { stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
  } catch {
    // Not a git checkout (e.g. an exported tarball) — the timestamp alone
    // still makes the name unique per build.
  }
  return sha === "" ? `dev-${hhmmss}` : `${sha}-${hhmmss}`;
};

// Resolve dmg-builder's compiled module and check the wrap target still looks
// like the function this hook was written against.
const loadDmgUtil = () => {
  let dmgUtil;
  try {
    dmgUtil = require("dmg-builder/out/dmgUtil");
  } catch (error) {
    fail(`cannot resolve dmg-builder/out/dmgUtil (${error && error.message})`);
  }
  if (typeof dmgUtil.customizeDmg !== "function") {
    fail("dmg-builder/out/dmgUtil no longer exports a customizeDmg function");
  }
  if (dmgUtil.customizeDmg.length !== 1) {
    fail(
      "customizeDmg arity changed (expected a single args-object parameter, " +
        `got arity ${dmgUtil.customizeDmg.length})`
    );
  }
  return dmgUtil;
};

// The wrap only takes effect if dmg.js calls customizeDmg THROUGH THE MODULE
// OBJECT (`(0, dmgUtil_1.customizeDmg)(…)`); a destructured local would
// capture the original and bypass the patch with no error. Likewise dmgUtil
// must forward contents entries' name/type verbatim into the dmgbuild
// settings JSON, or the injected `type: "position"` records are dropped
// before dmgbuild ever sees them. Assert both seams against the compiled
// sources at install time.
const assertDmgBuilderSeams = () => {
  const dmgJs = fs.readFileSync(require.resolve("dmg-builder/out/dmg"), "utf8");
  if (!dmgJs.includes(".customizeDmg)(")) {
    fail(
      "dmg-builder/out/dmg no longer calls customizeDmg through the module " +
        "object, so the Finder-layout wrap would never run"
    );
  }
  const dmgUtilJs = fs.readFileSync(require.resolve("dmg-builder/out/dmgUtil"), "utf8");
  if (!dmgUtilJs.includes("name: c.name") || !dmgUtilJs.includes("c.type")) {
    fail(
      "dmg-builder/out/dmgUtil no longer forwards contents name/type " +
        "verbatim, so the injected position entries would be dropped"
    );
  }
};

let installed = false;
let wrapperRan = false;

const installFinderLayoutPatch = () => {
  if (installed) {
    return;
  }
  installed = true;
  const dmgUtil = loadDmgUtil();
  assertDmgBuilderSeams();
  const realCustomizeDmg = dmgUtil.customizeDmg;
  dmgUtil.customizeDmg = async args => {
    wrapperRan = true;
    const volumeName =
      process.env.SYRUS_RELEASE_BUILD === "1"
        ? args.volumeName
        : `${args.volumeName} (${devVolumeNameSuffix()})`;
    const contents = [
      ...(args.specification.contents ?? []),
      ...Object.entries(HELPER_ICON_POSITIONS).map(([name, { x, y }]) => ({
        name,
        x,
        y,
        type: "position",
      })),
    ];
    // Belt and braces: every injected entry must actually be in the settings
    // handed through, or the DMG ships with the default layout.
    for (const name of Object.keys(HELPER_ICON_POSITIONS)) {
      if (!contents.some(entry => entry.name === name && entry.type === "position")) {
        fail(`the injected position entry for ${name} did not survive into the customizeDmg settings`);
      }
    }
    return realCustomizeDmg({
      ...args,
      volumeName,
      specification: { ...args.specification, contents },
    });
  };
  // Safety net for drift the source checks cannot see (e.g. a duplicated
  // dmg-builder in the module graph, where this hook patches a different
  // module instance than the one dmg.js actually calls): once a DMG build
  // has started, the wrapper MUST have run by process exit. Failing here is
  // late but loud — the alternative is silently shipping a default-layout
  // DMG.
  process.on("exit", () => {
    if (!wrapperRan) {
      console.error(
        "dmg-finder-layout: the customizeDmg wrap was installed but never " +
          "invoked — the DMG (if built) has the DEFAULT layout. Most likely " +
          "electron-builder/dmg-builder version drift or a duplicated " +
          "dmg-builder in the module graph."
      );
      process.exitCode = 1;
    }
  });
};

// electron-builder resolves this by export name. The DMG artifact's "build
// started" event fires inside DmgTarget#build right before customizeDmg, so
// installing the wrap here is always early enough — including `--prepackaged`
// runs, where beforePack-style hooks never fire.
exports.artifactBuildStarted = async event => {
  if ((event == null ? undefined : event.targetPresentableName) !== "DMG") {
    return;
  }
  installFinderLayoutPatch();
};

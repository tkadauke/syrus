# frozen_string_literal: true

require "json"
require "spec_helper"

# Distribution config: the DMG a user downloads must be signable, notarizable,
# and auto-updatable. These assertions pin the load-bearing electron-builder
# settings and the backend-asset staging contract.
RSpec.describe "desktop packaging" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:builder_config) { read("electron-builder.yml") }
  let(:package_json) { JSON.parse(read("package.json")) }
  let(:staging_script) { read("scripts/stage-backend-assets.mjs") }

  it "moves the build config out of package.json into electron-builder.yml" do
    expect(package_json).not_to have_key("build")
    expect(builder_config).to include("appId: app.syrus.desktop")
  end

  it "ships as Syrus.app, mirroring Claude Desktop naming" do
    expect(builder_config).to include("productName: Syrus\n")
    # Electron derives app.name — and the userData dir — from package.json's
    # productName; without it the packaged app stores config under the npm
    # package name instead of "Syrus".
    expect(package_json["productName"]).to eq("Syrus")
  end

  it "configures Gatekeeper-clean signing: hardened runtime, entitlements, notarization" do
    expect(builder_config).to include("hardenedRuntime: true")
    expect(builder_config).to include("entitlements: build/entitlements.mac.plist")
    expect(builder_config).to include("notarize: true")
    expect(File).to exist(File.join(desktop_root, "build/entitlements.mac.plist"))
  end

  it "keeps entitlements minimal — no library-validation opt-out" do
    entitlements = read("build/entitlements.mac.plist")
    expect(entitlements).to include("com.apple.security.cs.allow-jit")
    expect(entitlements).not_to include("<key>com.apple.security.cs.disable-library-validation</key>")
  end

  it "builds the zip target auto-update requires alongside the dmg" do
    expect(builder_config).to match(/- target: dmg\s+arch:/)
    expect(builder_config).to match(/- target: zip\s+arch:/)
  end

  it "lays the DMG out as double-click install: one centered icon, no drag target" do
    # The app self-installs into ~/Applications on first launch
    # (electron/selfInstall.ts) — a drag target would be a competing,
    # worse instruction.
    expect(builder_config).not_to include("type: link")
    expect(builder_config).not_to include("path: /Applications")
    expect(builder_config).to include("background: build/dmg-background.tiff")
    expect(File).to exist(File.join(desktop_root, "build/dmg-background.tiff"))
    expect(File).to exist(File.join(desktop_root, "build/dmg-background@2x.png"))
    expect(File).to exist(File.join(desktop_root, "scripts/render-dmg-background.mjs"))
  end

  describe "DMG Finder layout" do
    let(:layout_hook) { read("scripts/dmg-finder-layout.cjs") }
    let(:render_script) { read("scripts/render-dmg-background.mjs") }

    # Reads width/height (tags 256/257) from the FIRST page of a TIFF — the
    # 1x page tiffutil -cathidpicheck writes first, and the page dmg-builder's
    # sips call measures to size the Finder window frame.
    #
    # Raw String#byteslice is deliberate: this parses BINARY data, where the
    # safe_byteslice core extension (which re-encodes to UTF-8 and strips
    # invalid bytes) would corrupt the reads. The UTF-8 truncation convention
    # applies to text bound for persistence/logs/prompts/UI, not file headers.
    def tiff_first_page_dimensions(path)
      data = File.binread(path)
      endian = data.byteslice(0, 2) == "II" ? "v" : "n"
      long = endian == "v" ? "V" : "N"
      ifd_offset = data.byteslice(4, 4).unpack1(long)
      entry_count = data.byteslice(ifd_offset, 2).unpack1(endian)
      dims = {}
      entry_count.times do |i|
        entry = data.byteslice(ifd_offset + 2 + (i * 12), 12)
        tag = entry.byteslice(0, 2).unpack1(endian)
        next unless [256, 257].include?(tag)

        type = entry.byteslice(2, 2).unpack1(endian)
        value = type == 3 ? entry.byteslice(8, 2).unpack1(endian) : entry.byteslice(8, 4).unpack1(long)
        dims[tag] = value
      end
      [dims[256], dims[257]]
    end

    it "wires the Finder-layout hook into the DMG build" do
      expect(builder_config).to include("artifactBuildStarted: ./scripts/dmg-finder-layout.cjs")
      expect(File).to exist(File.join(desktop_root, "scripts/dmg-finder-layout.cjs"))
    end

    it "uniquifies dev volume names and keeps release names canonical" do
      # Finder caches icon-view window geometry per VOLUME NAME, so dev
      # builds that all mount as "Syrus 0.0.0" reuse stale (possibly
      # user-mangled) geometry — the shipped too-small-window bug. Releases
      # self-heal via the per-version name and must stay canonical for a
      # trustworthy install experience.
      expect(layout_hook).to include('process.env.SYRUS_RELEASE_BUILD === "1"')
      expect(layout_hook).to include("devVolumeNameSuffix")
      expect(builder_config).to include("title: Syrus ${version}")
    end

    it "parks dmgbuild's helper dotfiles below the visible window" do
      # Show-hidden-files users otherwise see .background.tiff & friends
      # auto-arranged INSIDE the 660x400 design area.
      %w[.background.tiff .VolumeIcon.icns .DS_Store .fseventsd].each do |name|
        expect(layout_hook).to include(%("#{name}"))
      end
      expect(layout_hook).to include('type: "position"')
      positions = layout_hook.scan(/\{ x: (\d+), y: (\d+) \}/).map { |x, y| [Integer(x), Integer(y)] }
      expect(positions.length).to be >= 4
      positions.each do |x, y|
        # Below the 400pt design (icons are 128pt, centers at y - the row
        # must clear 400 + half an icon)…
        expect(y).to be >= 400 + 64
        # …but within the 660pt width so hidden-files users never get a
        # horizontal scroll extent.
        expect(x).to be_between(64, 660 - 64)
      end
    end

    it "sizes the window frame from the background: 660x400 design plus title-bar pad" do
      width = Integer(render_script[/^const WIDTH = (\d+)$/, 1])
      design_height = Integer(render_script[/^const DESIGN_HEIGHT = (\d+)$/, 1])
      pad = Integer(render_script[/^const TITLE_BAR_PAD = (\d+)$/, 1])
      expect(width).to eq(660)
      expect(design_height).to eq(400)
      # Finder places the title bar INSIDE the frame dmgbuild writes to
      # .DS_Store; ~33pt on current macOS. A pad-less frame clips the
      # bottom of the design (the motto sat right on the cut line).
      expect(pad).to be_between(28, 40)
      # dmg-builder ignores dmg.window when a background is set and sizes
      # the frame from the tiff's 1x page; the yml block is kept in sync as
      # documentation.
      expect(builder_config).to match(/window:\s+width: #{width}\s+height: #{design_height + pad}/)
      # The checked-in tiff must actually have those dimensions, or the
      # shipped window frame drifts from the config story.
      tiff = File.join(desktop_root, "build/dmg-background.tiff")
      expect(tiff_first_page_dimensions(tiff)).to eq([width, design_height + pad])
    end

    it "self-validates the dmg-builder seams at build time and fails the build on drift" do
      # The node_modules-gated example below skips wherever desktop deps
      # aren't installed — which is every CI pipeline — so the HOOK is the
      # real enforcement point: at DMG-build time (the one place node_modules
      # must exist) it re-checks every seam it relies on and THROWS rather
      # than silently producing a default-layout DMG. These are source-level
      # pins on that self-validation, so they run everywhere.
      expect(layout_hook).to include('require("dmg-builder/out/dmgUtil")')
      expect(layout_hook).to include('typeof dmgUtil.customizeDmg !== "function"')
      expect(layout_hook).to include("dmgUtil.customizeDmg.length !== 1")
      # The wrap-bypass seams (dmg.js must call through the module object;
      # dmgUtil must forward name/type verbatim) are re-asserted from the
      # compiled sources at install time.
      expect(layout_hook).to include('require.resolve("dmg-builder/out/dmg")')
      expect(layout_hook).to include('.customizeDmg)(')
      expect(layout_hook).to include('"name: c.name"')
      # Injected entries are re-checked in the settings actually handed
      # through to the real customizeDmg.
      expect(layout_hook).to match(/entry\.name === name && entry\.type === "position"/)
      # Every validation failure raises (failing the electron-builder run) —
      # never a warn-and-continue — and names the likely cause.
      expect(layout_hook).to include("throw new Error(")
      expect(layout_hook).to include("version drift")
      expect(layout_hook).not_to include("console.warn")
    end

    it "fails the build when the customizeDmg wrap never ran after a DMG build started" do
      # Last-ditch net for drift the source checks cannot see (e.g. a
      # duplicated dmg-builder in the module graph, where the hook patches a
      # different module instance than the one dmg.js calls): the wrapper
      # marks a flag when invoked, and a process-exit check turns
      # "installed but never ran" into a nonzero exit instead of a silently
      # default-layout DMG.
      expect(layout_hook).to include("wrapperRan = true")
      expect(layout_hook).to match(/process\.on\("exit", \(\) => \{/)
      expect(layout_hook).to match(/if \(!wrapperRan\) \{/)
      expect(layout_hook).to include("process.exitCode = 1")
    end

    it "pins the dmg-builder seams the layout hook relies on" do
      dmg_builder_out = File.join(desktop_root, "node_modules/dmg-builder/out")
      skip "desktop node_modules not installed" unless File.directory?(dmg_builder_out)

      # The hook wraps the customizeDmg export; dmg.js must call through the
      # module object (not a destructured local) for the wrap to take effect.
      dmg_js = File.read(File.join(dmg_builder_out, "dmg.js"), encoding: "UTF-8")
      expect(dmg_js).to include("dmgUtil_1.customizeDmg)(")
      # dmgUtil must forward contents entries (incl. our type: "position" and
      # name overrides) verbatim into the dmgbuild settings JSON.
      dmg_util = File.read(File.join(dmg_builder_out, "dmgUtil.js"), encoding: "UTF-8")
      expect(dmg_util).to include('type: c.type === "dir" ? "file" : c.type')
      expect(dmg_util).to include("name: c.name")
    end
  end

  it "publishes to the tkadauke/syrus GitHub feed the shipped apps will read" do
    expect(builder_config).to match(/provider: github\s+owner: tkadauke\s+repo: syrus/)
    # Without releaseType, electron-builder creates DRAFT releases —
    # invisible to auto-update and the releases/latest download permalink.
    expect(builder_config).to include("releaseType: release")
  end

  it "bundles the backend installer assets as sealed extraResources" do
    expect(builder_config).to match(/extraResources:\s+- from: resources\/backend\s+to: backend/)
    expect(package_json.dig("scripts", "build")).to include("stage:backend")
  end

  it "stages both installer scripts, compose file, env template, and a version-pinned manifest" do
    %w[install.sh install.ps1 docker-compose.yml compose.env.example].each do |asset|
      expect(staging_script).to include(%("#{asset}"))
    end
    expect(staging_script).to include("ghcr.io/tkadauke/syrus-backend:${version}")
    expect(staging_script).to include('ghcr.io/tkadauke/syrus-backend:latest')
    expect(staging_script).to include("manifest.json")
    # Only actual release-workflow builds pin the versioned tag; a local
    # `npm run build` at a release-looking version must not pin an image
    # that was never published.
    expect(staging_script).to include('process.env.SYRUS_RELEASE_BUILD === "1"')
  end

  it "keeps staged resources out of git" do
    gitignore = File.read(File.expand_path("../../.gitignore", __dir__), encoding: "UTF-8")
    expect(gitignore).to include("desktop/resources/")
  end
end

# frozen_string_literal: true

require "spec_helper"

# The desktop "Connect to your Syrus" flow: URL-only by design (the tray
# token is minted from the signed-in web session; manual token entry lives
# in Preferences for non-admin accounts), bare IPs/hosts accepted with
# http:// and :3000 assumed, and probe failures classified into actionable
# messages instead of a generic "could not connect".
RSpec.describe "desktop connect flow" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  def desktop_i18n
    read("src/i18n.ts")
  end

  it "keeps the two instanceUrl copies byte-identical" do
    # The renderer (live preview) and the main process (authoritative
    # normalization) cannot share a module across tsconfig rootDir
    # boundaries, so the pure analyzer exists twice. They must never drift.
    renderer_copy = read("src/onboarding/instanceUrl.ts")
    driver_copy = read("electron/installer/instanceUrl.ts")
    expect(driver_copy).to eq(renderer_copy)
  end

  it "connects with a URL only — no token crosses the onboarding IPC" do
    expect(read("electron/preload.cts")).to match(/type ConnectRemoteRequest = \{\s*url: string\s*\}/m)
    connect_form = read("src/onboarding/ConnectRemote.tsx")
    # No token input; the design decision is stated in the component.
    expect(connect_form).not_to match(/type="password"/)
    expect(connect_form).to include("deliberately no API-token")
    driver = read("electron/installer/installerDriver.ts")
    expect(driver).to match(/connectRemote\(request: \{ url: string \}\)/)
    expect(driver).not_to include("saveRemoteCredentials")
  end

  it "normalizes bare hosts through the shared analyzer before probing" do
    driver = read("electron/installer/installerDriver.ts")
    expect(driver).to include('import { analyzeInstanceUrl } from "./instanceUrl.js"')
    expect(driver).to match(/const analysis = analyzeInstanceUrl\(request\.url\)/)
  end

  it "guards the async probe against Back-navigation races" do
    # Back stays enabled while checking (by design), so the fingerprint can
    # lose a race against the user navigating away. A stale success must not
    # persist a backend choice the user abandoned; a stale failure must not
    # yank the wizard out of wherever they went. Mirrors the file's existing
    # convention in startRuntime/openOrbStackDownload.
    driver = read("electron/installer/installerDriver.ts")
    connect = driver[/async connectRemote[\s\S]{0,2200}/]
    expect(connect).to include('this.state.phase === "connect.checking" && this.state.url === serverUrl')
    expect(connect.scan(/if \(!stillChecking\(\)\) \{/).length).to eq(2)
  end

  it "honors an explicitly typed :80 instead of assuming :3000" do
    # The WHATWG parser drops scheme-default ports, so the analyzer must
    # consult the raw input before assuming Syrus's default.
    analyzer = read("src/onboarding/instanceUrl.ts")
    expect(analyzer).to include('const typedPort = /:\d+$/.test(input)')
    expect(analyzer).to match(/!hasScheme && !typedPort && url\.port === ""/)
  end

  it "classifies probe failures into actionable messages" do
    fingerprint = read("electron/installer/fingerprint.ts")
    expect(fingerprint).to include("Nothing answered at")
    # The :3000 suggestion appears only in the forgot-the-port failure case,
    # never as a lecture on healthy input (production is https, no port).
    expect(fingerprint).to include("local installs use :3000")
    expect(fingerprint).to match(/const portless = !\/:\\d\+\$\/\.test\(url\)/)
    # Rails host authorization is a server-side fix; the error must say so.
    expect(fingerprint).to include("SYRUS_ALLOWED_HOSTS")
    expect(fingerprint).to include("doesn't look like a Syrus instance")
    # The classifier stays Electron-free so vitest can exercise the branches
    # behaviorally (desktop/src/fingerprint.test.ts); the driver imports it.
    expect(fingerprint).not_to include('from "electron"')
    driver = read("electron/installer/installerDriver.ts")
    expect(driver).to include('import { fingerprintSyrus } from "./fingerprint.js"')
  end

  it "backs the live check with a stateless probe — green means a Syrus answered" do
    driver = read("electron/installer/installerDriver.ts")
    probe = driver[/async probeInstance[\s\S]*?(?=\n  \/\/ URL-only by design)/]
    # Stateless: a stale probe result must not be able to race wizard state.
    expect(probe).not_to include("setState")
    expect(probe).to include("fingerprintSyrus")
    expect(read("electron/main.ts")).to include('ipcMain.handle("onboarding:probe-instance"')

    form = read("src/onboarding/ConnectRemote.tsx")
    expect(form).to include("probeInstance")
    # Debounced, and stale results are discarded by sequence number.
    expect(form).to include("PROBE_DEBOUNCE_MS")
    expect(form).to include("probeSeq")
    expect(form).to include('t("onboarding.connect.found", { url: probe.url })')
    expect(desktop_i18n).to include("Syrus found at")
  end

  it "rejects partial numeric hosts instead of previewing a mangled address" do
    # new URL("http://192.168.") normalizes to host 192.0.0.168 — the
    # analyzer must consult the typed host before the parser rewrites it.
    analyzer = read("src/onboarding/instanceUrl.ts")
    expect(analyzer).to include("looksLikePartialIpv4")
    expect(analyzer).to include("Doesn't look like a server address yet.")
  end

  it "bounds the Preferences credential validation so the form can't hang forever" do
    main = read("electron/main.ts")
    validate = main[/const validateCredentialsWithServer[\s\S]{0,700}/]
    expect(validate).to include("AbortSignal.timeout")
  end
end

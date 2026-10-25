# frozen_string_literal: true

require "spec_helper"

# The failure this guards against: the local backend's database is rebuilt
# (Docker wipe, reinstall) while ~/.syrus/credentials survives on disk with
# a token the new database has never seen. Every app API call then 401s,
# and — before this fix — the token provisioner refused to re-mint because
# credentials for the instance "already existed". The app could never heal
# itself, and the shared CLI stayed broken too.
RSpec.describe "desktop stale-token healing" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:desktop_root) { File.join(repo_root, "desktop") }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:main) { read("electron/main.ts") }
  let(:provisioner) { read("electron/tokenProvisioner.ts") }
  let(:renderer) { read("src/App.tsx") }

  it "marks credentials suspect on any 401 from the app API" do
    expect(main).to include("let suspectTokenKey: string | null = null")
    expect(main).to match(/const throwIfUnauthorized[\s\S]{0,300}status === 401[\s\S]{0,200}suspectTokenKey = credentialsKey\(credentials\)/)
    # Every Bearer-authenticated helper must run through the 401 check —
    # except validateCredentialsWithServer, which probes CANDIDATE
    # credentials before saving and must not mark the saved ones.
    bearer_sites = main.scan(/Authorization: `Bearer/).size
    checks = main.scan(/throwIfUnauthorized\(credentials, response\)/).size
    expect(checks).to eq(bearer_sites - 1),
      "expected #{bearer_sites - 1} throwIfUnauthorized calls for #{bearer_sites} Bearer fetches, found #{checks}"
  end

  it "lets the provisioner overwrite same-instance credentials the server rejected" do
    expect(provisioner).to include("credentialsSuspect?: (credentials: Credentials) => boolean")
    # Different-instance credentials stay untouchable even when suspect.
    expect(provisioner).to match(/normalizeUrl\(cached\.url\) !== normalized[\s\S]{0,120}"different-instance"/)
    expect(provisioner).to match(/credentialsSuspect\?\.\(cached\)[\s\S]{0,120}"already-configured"/)

    expect(main).to match(/credentialsSuspect: \(credentials\) => suspectTokenKey === credentialsKey\(credentials\)/)
    # A successful save (provisioned or manual) clears the suspicion.
    expect(main).to match(/cachedCredentials = normalizedCredentials\s+suspectTokenKey = null/)
  end

  it "keeps the unauthorized marker in sync between main and the tray renderer" do
    marker = renderer[/const UNAUTHORIZED_MARKER = "([^"]+)"/, 1]
    expect(marker).not_to be_nil
    message = main[/const UNAUTHORIZED_MESSAGE = "([^"]+)"/, 1]
    expect(message).not_to be_nil
    # The renderer only sees the stringified error, so it substring-matches;
    # the marker must therefore be contained in the thrown message.
    expect(message).to include(marker)
  end

  it "routes the tray's unauthorized state to Open Syrus, not a dead-end retry" do
    expect(renderer).to include("isUnauthorizedError(inboxQuery.error)")
    unauthorized_panel = renderer[/isUnauthorizedError\(inboxQuery\.error\)[\s\S]{0,700}/]
    expect(unauthorized_panel).to include('t("renderer.signin_refresh")')
    expect(read("electron/i18nCatalog.ts")).to include('"renderer.signin_refresh": "Sign-in needs a refresh"')
    expect(unauthorized_panel).to include("openSyrusWindow")
  end

  it "points Preferences' token link at the instance's own settings page" do
    handler = main[/ipcMain\.handle\("open-token-docs"[\s\S]{0,600}/]
    expect(handler).to include("/settings")
    expect(handler).to include("showWebAppWindow()")
    # Public docs stay only as the no-instance fallback.
    expect(handler).to include("TOKEN_DOCS_URL")
  end
end

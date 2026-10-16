# frozen_string_literal: true

require "spec_helper"

# The desktop app mints its menu-bar Bearer token from the signed-in webview
# session (POST /api/v1/app/desktop/api_token) instead of making users paste
# one. These assertions pin the client half of that contract; the Rails half
# lives in spec/requests/api/v1/app/desktop_tokens_spec.rb.
RSpec.describe "desktop token provisioning" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:provisioner) { read("electron/tokenProvisioner.ts") }
  let(:main_process) { read("electron/main.ts") }

  it "runs inside the page so the session cookie and CSRF meta tag come for free" do
    expect(provisioner).to include("webContents.executeJavaScript(PROVISION_SCRIPT, true)")
    expect(provisioner).to include('meta[name="csrf-token"]')
    expect(provisioner).to include('"X-CSRF-Token": csrf')
    expect(provisioner).to include('"/api/v1/app/desktop/api_token"')
  end

  it "only provisions for signed-in sessions and never touches the rotate endpoint" do
    expect(provisioner).to include("statusPayload.authenticated !== true")
    expect(provisioner).not_to include("rotate_api_token")
  end

  it "falls back silently for non-admins and skips when credentials already match" do
    expect(provisioner).to include('"forbidden"')
    expect(provisioner).to include('"already-configured"')
  end

  it "never overwrites credentials configured for a different instance" do
    # ~/.syrus/credentials is shared with the syrus CLI; auto-provisioning
    # against instance B must not silently retarget a CLI pointed at A.
    expect(provisioner).to include('"different-instance"')
    expect(provisioner).to match(/if \(cached\) \{[\s\S]{0,400}different-instance/)
  end

  it "keeps the app window in lockstep with a Preferences URL change (remote mode)" do
    save_credentials = main_process[/const saveCredentials = async[\s\S]*?\n\}/]
    expect(save_credentials).to include('getBackendMode() === "remote"')
    expect(save_credentials).to include('saveBackendConfig({ mode: "remote", serverUrl: normalizedServerUrl })')
  end

  it "persists through main.ts's saveCredentials (validation + cable + 0600 file)" do
    expect(provisioner).not_to include("writeCredentialsFile")
    expect(main_process).to include("maybeProvisionDesktopToken")
  end

  it "triggers on full loads AND in-page navigations — SPA sign-in fires no did-finish-load" do
    expect(main_process).to include('.on("did-finish-load", attemptTokenProvisioning)')
    expect(main_process).to include('.on("did-navigate-in-page", attemptTokenProvisioning)')
    expect(provisioner).to include("attemptInFlight")
  end

  it "keeps explicit sign-out authoritative across later web-app navigations" do
    delete_credentials = main_process[/const deleteCredentials = async[\s\S]*?\n\}/]
    save_credentials = main_process[/const saveCredentials = async[\s\S]*?\n\}/]

    expect(delete_credentials).to include("autoProvisioningAllowed = false")
    expect(save_credentials).to include("autoProvisioningAllowed = true")
    expect(main_process).to include("autoProvisioningAllowed: () => autoProvisioningAllowed")
    expect(provisioner).to match(/if \(!deps\.autoProvisioningAllowed\(\)\) \{[\s\S]{0,100}suppressed/)
  end

  it "does not overwrite credentials changed while page provisioning is in flight" do
    expect(provisioner).to include("credentialsMatch(cached, deps.getCachedCredentials())")
    expect(provisioner).to match(
      /await Promise\.race[\s\S]*credentialsMatch\(cached, deps\.getCachedCredentials\(\)\)[\s\S]*deps\.saveCredentials/
    )
  end

  it "bounds the in-page script so a torn-down frame cannot wedge provisioning" do
    # executeJavaScript's promise never settles when its frame is destroyed
    # mid-flight; unbounded, the attemptInFlight latch would stick for the
    # rest of the app run.
    expect(provisioner).to include("EXECUTE_TIMEOUT_MS")
    expect(provisioner).to match(/Promise\.race\(\[\s*\n\s*execution/)
    # The abandoned execution promise must not surface as an unhandled
    # rejection after the race moves on.
    expect(provisioner).to include("execution.catch(() => {})")
  end

  it "latches a 403 per instance so SPA route changes stop re-POSTing" do
    expect(provisioner).to include("forbiddenInstanceUrl = normalized")
    expect(provisioner).to match(/normalized === forbiddenInstanceUrl/)
  end

  it "prefills the tray setup form with the configured instance URL" do
    preload = read("electron/preload.cts")
    app_tsx = read("src/App.tsx")
    expect(main_process).to include('ipcMain.handle("get-server-url"')
    expect(preload).to include('getServerUrl: () => ipcRenderer.invoke("get-server-url")')
    expect(app_tsx).to include('window.syrusDesktop.getServerUrl().catch(() => "")')
  end

  it "only runs against same-origin pages, never the fallback surface" do
    expect(main_process).to include("new URL(handle.window.webContents.getURL()).origin === new URL(serverUrl).origin")
  end
end

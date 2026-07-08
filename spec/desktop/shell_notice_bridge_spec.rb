# frozen_string_literal: true

require "spec_helper"

# The shell-notice bridge: the web-app window's ONLY preload
# (webAppPreload.cts), exposing window.syrusShell so the web app's sidebar
# can render a staged auto-update and the one-time Claude Code skill offer
# as inline notices. This replaced two interruptive native dialogs. The web
# frontend builds against this exact contract — the shape below is an API,
# not an implementation detail.
RSpec.describe "desktop shell-notice bridge" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:desktop_root) { File.join(repo_root, "desktop") }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:preload) { read("electron/windows/webAppPreload.cts") }
  let(:main) { read("electron/main.ts") }

  it "exposes exactly the syrusShell contract the web app builds against" do
    expect(preload).to include('contextBridge.exposeInMainWorld("syrusShell"')
    # The five members, verbatim — the web agent codes against these names.
    expect(preload).to match(/getState: \(\) => ipcRenderer\.invoke\("shell:get-state"\)/)
    expect(preload).to include('ipcRenderer.on("shell:state-changed", listener)')
    expect(preload).to include('ipcRenderer.removeListener("shell:state-changed", listener)')
    expect(preload).to match(/relaunchToUpdate: \(\) => \{\s*\n\s*void ipcRenderer\.invoke\("shell:relaunch-to-update"\)/)
    expect(preload).to match(/installSkill: \(\) =>\s*\n?\s*ipcRenderer\.invoke\("shell:install-skill"\)/)
    expect(preload).to match(/dismissSkillOffer: \(\) => \{\s*\n\s*void ipcRenderer\.invoke\("shell:dismiss-skill-offer"\)/)
    # onStateChanged returns an unsubscribe, mirroring the tray bridge style.
    expect(preload).to match(/onStateChanged: \(callback: \(state: ShellNoticeState\) => void\) => \{/)
    # The state shape is the contract's other half.
    expect(preload).to include("updateReadyVersion: string | null")
    expect(preload).to include("claudeDetected: boolean")
    expect(preload).to include("skillInstalled: boolean")
    expect(preload).to include("skillOfferDismissed: boolean")
    # installSkill resolves { ok, message } — failures render inline, no dialog.
    expect(preload).to include("Promise<{ ok: boolean; message: string | null }>")
    # Nothing beyond the contract leaks across: no node built-ins, no second
    # exposeInMainWorld, no credentials/filesystem channels.
    expect(preload.scan("exposeInMainWorld").length).to eq(1)
    expect(preload).not_to match(/require\("node:|from "node:/)
    expect(preload).not_to include("get-credentials")
  end

  it "computes the notice state in the main process from real sources" do
    state = main[/const shellNoticeState[\s\S]{0,700}/]
    expect(state).to include("updateReadyVersion: appUpdates.downloadedUpdateVersion()")
    expect(state).to include("claudeDetected: await agentToolPresent()")
    expect(state).to include("claudeSkillPath()")
    expect(state).to include("skillOfferDismissed: skillOfferDismissed()")
    # Handlers for all four channels.
    expect(main).to include('ipcMain.handle("shell:get-state"')
    expect(main).to include('ipcMain.handle("shell:relaunch-to-update"')
    expect(main).to include('ipcMain.handle("shell:install-skill"')
    expect(main).to include('ipcMain.handle("shell:dismiss-skill-offer"')
    # Dismissal persists and re-broadcasts so open pages update live.
    dismiss = main[/ipcMain\.handle\("shell:dismiss-skill-offer"[\s\S]{0,400}/]
    expect(dismiss).to include('store.set("skillOfferDismissed", true)')
    expect(dismiss).to include("broadcastShellNoticeState()")
  end

  it "validates the sender on EVERY shell:* handler — top frame of the app window, instance origin only" do
    # ipcMain.handle answers any renderer in the process; shell:* actions
    # write to the host (skill file) or restart the app, so each handler
    # re-validates the sender before acting. Three checks, in order: the
    # sending webContents IS the web-app window, the invoking frame IS that
    # window's top frame, and the frame's CURRENT URL sits on the configured
    # instance origin — resolved by the SAME resolveInstanceOrigin the
    # tray's Open-in-Syrus path trusts. Mismatches log and refuse.
    guard = main[/const shellSenderAllowed[\s\S]{0,1800}/]
    expect(guard).to include("event.sender !== contents")
    expect(guard).to include("frame !== contents.mainFrame")
    expect(guard).to include("resolveInstanceOrigin(getServerUrl())")
    expect(guard).to include("new URL(frame.url).origin")
    expect(guard).to match(/instanceOrigin === null \|\| senderOrigin !== instanceOrigin/)
    expect(guard.scan(/console\.warn\(\s*`\[shell-ipc\] refused/).length).to eq(3)
    expect(guard.scan("return false").length).to eq(3)
    # A destroyed/absent senderFrame is a refusal, not a crash.
    expect(guard).to match(/if \(!frame \|\| frame !== contents\.mainFrame\)/)

    # Each of the four handlers runs the guard BEFORE any action.
    %w[shell:get-state shell:relaunch-to-update shell:install-skill shell:dismiss-skill-offer].each do |channel|
      handler = main[/ipcMain\.handle\("#{Regexp.escape(channel)}", (?:async )?\(event\) => \{[\s\S]{0,300}/]
      expect(handler).to include("if (!shellSenderAllowed(event, \"#{channel}\"))"),
        "#{channel} must validate the sender first"
    end

    # Refusals never act: get-state answers an inert no-notices state (leaks
    # nothing about the host), install-skill answers an inline failure, the
    # other two return early.
    expect(main).to include("const INERT_SHELL_NOTICE_STATE: ShellNoticeState")
    inert = main[/const INERT_SHELL_NOTICE_STATE[\s\S]{0,400}/]
    expect(inert).to include("updateReadyVersion: null")
    expect(inert).to include("claudeDetected: false")
    expect(inert).to include("skillOfferDismissed: true")
    get_state = main[/ipcMain\.handle\("shell:get-state"[\s\S]{0,300}/]
    expect(get_state).to include("return INERT_SHELL_NOTICE_STATE")
    install = main[/ipcMain\.handle\("shell:install-skill"[\s\S]{0,400}/]
    expect(install).to include("return { ok: false, message:")
  end

  it "re-checks the skill offer's gates server-side, not just in the sidebar" do
    install = main[/const installSkillFromShell[\s\S]{0,2600}/]
    # The renderer's claim is not trusted: no detected coding agent means no
    # writing into another tool's config dir; an already-installed skill is
    # idempotent success (and the broadcast clears the notice).
    expect(install).to match(/if \(!\(await agentToolPresent\(\)\)\)/)
    expect(install).to include("No coding agent (Claude Code or Codex) was detected")
    expect(install).to match(/alreadyInstalled[\s\S]{0,200}claudeSkillPath\(\)/)
    expect(install).to match(/if \(alreadyInstalled\) \{\s*\n\s*store\.set\("skillInstallOffered", true\)\s*\n\s*return \{ ok: true, message: null \}/)
  end

  it "refreshes the sidebar notice after EVERY install path, not just the shell bridge's" do
    # Preferences and the tray banner (install-syrus-cli IPC), the
    # launch/onboarding auto-install (ensureCliCurrent), and the shell
    # bridge's repair fallback all funnel through performCliInstall — its
    # finally re-broadcasts so a successful skill install clears the offer
    # without an app restart, and a successful skill install also stamps the
    # legacy asked-and-answered flag.
    install = main[/const performCliInstall[\s\S]{0,4400}/]
    expect(install).to match(/finally \{[\s\S]{0,600}void broadcastShellNoticeState\(\)/)
    expect(install).to match(/skillInstalled = true\s*\n[\s\S]{0,300}store\.set\("skillInstallOffered", true\)/)
  end

  it "turns update-downloaded into a broadcast, not a dialog" do
    # The staged update reaches the user as a sidebar notice (plus the
    # existing menu items) — never an interruptive dialog.
    on_downloaded = main[/onUpdateDownloaded: \(\) => \{[\s\S]{0,400}/]
    expect(on_downloaded).to include("broadcastShellNoticeState()")
    expect(on_downloaded).not_to include("dialog.")
    expect(main).to include('webAppWindow?.window.webContents.send("shell:state-changed", state)')
  end

  it "guards relaunchToUpdate and sets the quit flag before installing" do
    handler = main[/ipcMain\.handle\("shell:relaunch-to-update"[\s\S]{0,900}/]
    # A stray page call without a staged update must not quit a healthy app
    # (the no-op guard stays even behind the sender validation).
    expect(handler).to match(/if \(!appUpdates\.downloadedUpdateVersion\(\)\)/)
    # quitAndInstall closes windows BEFORE any quit event fires; without the
    # flag the tray's hide-on-close handler preventDefaults and aborts it.
    expect(handler).to match(/isQuitting = true\s*\n\s*appUpdates\.quitAndInstallUpdate\(\)/)
  end

  it "installs the skill through the existing CLI path and reports failures inline" do
    install = main[/const installSkillFromShell[\s\S]{0,2600}/]
    # Same audited path as Preferences: the CLI's own `skill install`, with
    # performCliInstall({ withSkill: true }) as the repair fallback.
    expect(install).to match(/execFileAsync\(localBinSyrus\(\), \["skill", "install"\]/)
    expect(install).to match(/performCliInstall\(\{ withSkill: true \}\)/)
    # Failure is a return value for the web UI, never an error dialog.
    expect(install).to include("return { ok: false, message:")
    expect(install).not_to include("dialog.")
    # Every outcome re-broadcasts so the notice disappears the moment the
    # skill lands.
    expect(install).to match(/finally \{\s*\n\s*void broadcastShellNoticeState\(\)/)
  end

  it "keeps the interruptive dialogs gone" do
    expect(main).not_to include("offerSkillIfAgentDetected")
    expect(main).not_to include("Coding agent detected")
    expect(main).not_to include("attemptSkillOffer")
    expect(main).not_to include("skillOfferInFlight")
  end
end

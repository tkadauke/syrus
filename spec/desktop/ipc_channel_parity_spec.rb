# frozen_string_literal: true

require "spec_helper"

# The desktop bridges are stringly typed: the preloads (preload.cts for the
# tray/preferences windows, webAppPreload.cts for the web-app window) invoke
# IPC channels by name and main.ts registers handlers by name, with no
# compile-time link between the files. Renaming a channel string on one side
# produces no TypeScript error — just a button that dies at runtime with "No
# handler registered for '<channel>'". This static scan pins the channel sets
# to each other so a one-sided rename fails CI instead of shipping a dead
# control.
RSpec.describe "desktop IPC channel parity" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:preloads) do
    %w[preload.cts windows/webAppPreload.cts].map do |name|
      File.read(File.join(repo_root, "desktop", "electron", name), encoding: "UTF-8")
    end.join("\n")
  end
  let(:main) { File.read(File.join(repo_root, "desktop", "electron", "main.ts"), encoding: "UTF-8") }

  let(:invoked_channels) { preloads.scan(/ipcRenderer\.invoke\("([^"]+)"/).flatten.uniq.sort }
  let(:handled_channels) { main.scan(/ipcMain\.handle\("([^"]+)"/).flatten.uniq.sort }

  it "registers a main-process handler for every channel a preload bridge invokes" do
    orphans = invoked_channels - handled_channels
    expect(orphans).to be_empty,
      "the preloads invoke channels with no ipcMain.handle in main.ts " \
      "(each one is a dead button at runtime): #{orphans.join(', ')}"
  end

  it "invokes every registered handler from a preload bridge (no dead handlers)" do
    # Currently every handler is renderer-facing. If a genuinely
    # main-process-only channel ever appears, add it to an explicit allowlist
    # here instead of weakening the scan.
    unused = handled_channels - invoked_channels
    expect(unused).to be_empty,
      "main.ts handles channels never invoked from any preload " \
      "(dead handler or a rename that missed a preload): #{unused.join(', ')}"
  end

  it "scanned a plausible number of channels on both sides" do
    # If either regex drifts from the source style (quote change, helper
    # wrapper, renamed import), both sets could silently collapse to empty
    # and the parity checks above would pass vacuously. 52 channels exist at
    # the time of writing; >= 50 leaves headroom without tracking the count.
    expect(invoked_channels.size).to be >= 50
    expect(handled_channels.size).to be >= 50
  end
end

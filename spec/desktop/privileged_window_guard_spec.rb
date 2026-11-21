# frozen_string_literal: true

require "spec_helper"

# Every window that gets the privileged preload.cjs bridge (saved token,
# credential writes, checkout, installer control) must be locked to the content
# the main process loaded into it. Without the lock, a link or file dropped onto
# the window navigated it, and the foreign page ran with that bridge.
# desktop/src/privilegedWindowGuard.test.ts covers the guard itself; this pins
# that each privileged window installs it.
RSpec.describe "desktop privileged windows" do
  root = File.expand_path("../..", __dir__)
  sources = Dir[File.join(root, "desktop/electron/**/*.ts")].to_h { |path| [path, File.read(path)] }

  it "locks every BrowserWindow that is given the privileged preload" do
    creations = sources.flat_map do |path, source|
      source.scan(/(\w+)\s*=\s*new BrowserWindow\(\{(?:(?!\n\s*\}\)).)*?preload:\s*(path\.join\(__dirname, "preload\.cjs"\)|preloadPath)/m)
        .map { |variable, preload| [path, variable, preload] }
    end
    privileged = creations.select do |path, _variable, preload|
      preload.include?("preload.cjs") || path.end_with?("onboardingWindow.ts")
    end

    expect(privileged.map { |path, variable, _| "#{File.basename(path)}:#{variable}" })
      .to contain_exactly("main.ts:mainWindow", "main.ts:preferencesWindow", "onboardingWindow.ts:window")
    privileged.each do |path, variable, _|
      expect(sources[path]).to include("lockPrivilegedWindow(#{variable}.webContents)"),
        "#{File.basename(path)} creates #{variable} with the privileged preload but never locks it"
    end
  end

  it "passes preload.cjs only to windows it locks" do
    preload_uses = sources.sum { |_path, source| source.scan('path.join(__dirname, "preload.cjs")').length }
    # popover + preferences in main.ts, and the onboarding window's preloadPath.
    expect(preload_uses).to eq(3)
  end
end

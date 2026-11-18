require "rails_helper"

RSpec.describe Syrus::PluginBootSafety do
  Plugin = Data.define(:name, :directory, :external)

  def plugin(root, name, external: true, body: "one")
    directory = root.join(name)
    directory.mkpath
    directory.join("plugin.rb").write(body)
    Plugin.new(name:, directory:, external:)
  end

  it "implements third_party, recent, and all safe modes against plugin files" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      external = plugin(root, "external")
      built_in = plugin(root, "built_in", external: false)
      path = root.join("state.json")

      third_party = described_class.new(path:, env: { "SYRUS_SAFE_MODE" => "third_party" })
      expect(third_party.skip_reason(external)).to include("third_party")
      expect(third_party.skip_reason(built_in)).to be_nil

      recent = described_class.new(path:, env: { "SYRUS_SAFE_MODE" => "recent" })
      recent.mark_good!([ external ])
      expect(recent.skip_reason(external)).to be_nil
      external.directory.join("plugin.rb").write("two")
      expect(recent.skip_reason(external)).to include("changed")

      all = described_class.new(path:, env: { "SYRUS_SAFE_MODE" => "all" })
      expect(all.skip_reason(external)).to include("not required")
      expect(all.skip_reason(built_in)).to include("not required")
    end
  end

  it "quarantines changed external plugins after failed boots within the window and promotes last-good with a fake clock" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      current_time = Time.utc(2026, 1, 1)
      env = { "SYRUS_BOOT_FAILURE_LIMIT" => "3", "SYRUS_BOOT_FAILURE_WINDOW_SECONDS" => "600" }
      ledger = described_class.new(path: root.join("state.json"), env:, clock: -> { current_time })
      candidate = plugin(root, "weather")
      ledger.mark_good!([ candidate ])
      candidate.directory.join("plugin.rb").write("changed")

      3.times { ledger.begin_boot!([ candidate ]); current_time += 1 }
      expect(ledger.skip_reason(candidate)).to be_nil
      ledger.begin_boot!([ candidate ])
      expect(ledger.skip_reason(candidate)).to include("crash loop")

      ledger.clear!(candidate.name)
      ledger.mark_good!([ candidate ])
      expect(ledger.skip_reason(candidate)).to be_nil
    end
  end

  it "drops failed attempts outside the crash-loop window" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      current_time = Time.utc(2026, 1, 1)
      ledger = described_class.new(path: root.join("state.json"), env: { "SYRUS_BOOT_FAILURE_LIMIT" => "1", "SYRUS_BOOT_FAILURE_WINDOW_SECONDS" => "10" }, clock: -> { current_time })
      candidate = plugin(root, "weather")
      ledger.begin_boot!([ candidate ])
      current_time += 11
      ledger.begin_boot!([ candidate ])
      expect(ledger.skip_reason(candidate)).to be_nil
    end
  end

  it "fails open for an invalid safe-mode value" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      candidate = plugin(root, "weather")
      ledger = described_class.new(path: root.join("state.json"), env: { "SYRUS_SAFE_MODE" => "typo" })

      expect { expect(ledger.skip_reason(candidate)).to be_nil }.to output(/Invalid SYRUS_SAFE_MODE/).to_stderr
    end
  end
end

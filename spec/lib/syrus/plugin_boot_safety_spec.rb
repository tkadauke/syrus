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
      env = { "SYRUS_BOOT_FAILURE_LIMIT" => "3", "SYRUS_BOOT_FAILURE_WINDOW_SECONDS" => "600", "SYRUS_BOOT_SUCCESS_AFTER_SECONDS" => "0" }
      ledger = described_class.new(path: root.join("state.json"), env:, clock: -> { current_time })
      candidate = plugin(root, "weather")
      ledger.mark_good!([ candidate ])
      candidate.directory.join("plugin.rb").write("changed")

      3.times do
        attempt_id = ledger.begin_boot!([ candidate ])
        ledger.send(:release_attempt_lease, attempt_id)
        current_time += 1
      end
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
      ledger = described_class.new(path: root.join("state.json"), env: { "SYRUS_BOOT_FAILURE_LIMIT" => "1", "SYRUS_BOOT_FAILURE_WINDOW_SECONDS" => "10", "SYRUS_BOOT_SUCCESS_AFTER_SECONDS" => "0" }, clock: -> { current_time })
      candidate = plugin(root, "weather")
      ledger.begin_boot!([ candidate ])
      current_time += 11
      ledger.begin_boot!([ candidate ])
      expect(ledger.skip_reason(candidate)).to be_nil
    end
  end

  it "preserves same-timestamp overlapping starts when they promote out of start order" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      current_time = Time.utc(2026, 1, 1)
      env = { "SYRUS_BOOT_FAILURE_LIMIT" => "1", "SYRUS_BOOT_FAILURE_WINDOW_SECONDS" => "600", "SYRUS_BOOT_SUCCESS_AFTER_SECONDS" => "60" }
      ledger = described_class.new(path: root.join("state.json"), env:, clock: -> { current_time })
      candidate = plugin(root, "weather")
      ledger.mark_good!([ candidate ])
      candidate.directory.join("plugin.rb").write("changed")

      first = ledger.begin_boot!([ candidate ])
      second = ledger.begin_boot!([ candidate ])
      expect(ledger.skip_reason(candidate)).to be_nil

      current_time += 60
      ledger.mark_good!([ candidate ], attempt_id: second)
      state = JSON.parse(root.join("state.json").read)
      expect(state.fetch("attempts").map { |attempt| attempt.fetch("id") }).to eq([ first ])

      third = ledger.begin_boot!([ candidate ])
      ledger.mark_good!([ candidate ], attempt_id: first)
      state = JSON.parse(root.join("state.json").read)
      expect(state.fetch("attempts").map { |attempt| attempt.fetch("id") }).to eq([ third ])
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

  it "only marks local quarantine as clearable when safe mode and fleet quarantine are absent" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      path = root.join("plugin-boot-safety.json")
      local = described_class.new(path:, env: {})
      local.quarantine!("weather")
      expect(local.locally_clearable?("weather")).to be(true)

      safe_mode = described_class.new(path:, env: { "SYRUS_SAFE_MODE" => "recent" })
      expect(safe_mode.locally_clearable?("weather")).to be(false)

      fleet_path = root.join("plugin-sync/fleet-quarantines.json")
      fleet_path.dirname.mkpath
      fleet_path.write(JSON.generate("weather" => "fleet quarantine"))
      expect(local.locally_clearable?("weather")).to be(false)
    end
  end
end

require "rails_helper"

RSpec.describe RuntimeImages::ConformanceProbe do
  let(:full_output) { described_class.expected_checks.map { |name| "ok #{name}" }.join("\n") + "\n" }

  def evaluate(output = full_output, status: 0, **opts) = described_class.evaluate(output, exit_status: status, **opts)

  describe "the definition" do
    it "is emitted by the shipped probe script" do
      expect(described_class.definition_problems).to eq([])
      expect(RuntimeImages::CoworkerBase.validate).to eq([])
    end

    it "fails when the probe script drops a provider" do
      script = described_class::SCRIPT.read.gsub("muse:/opt/muse/bin/muse", "")
      expect(described_class.definition_problems(script: script)).to include(/does not check muse at \/opt\/muse\/bin\/muse/)
    end

    it "fails when the probe script drops a support tool, confinement check, or MCP check" do
      script = described_class::SCRIPT.read.sub("NoNewPrivs", "").gsub("mcp-socket-dir", "").sub("unzip; do", "; do")
      problems = described_class.definition_problems(script: script)
      expect(problems).to include(/confinement policy/, /check mcp-socket-dir/, /support tool unzip/)
    end

    it "fails when the probe script can exit zero after a failure" do
      script = described_class::SCRIPT.read.sub('exit "$status"', "exit 0")
      expect(described_class.definition_problems(script: script)).to include(/exit non-zero/)
    end
  end

  describe "contract tests every bundled provider must satisfy" do
    let(:bundled) do
      Dir[Rails.root.join("plugins/*_agent/app/services/agent_providers/*.rb")].map { |f| File.basename(f, ".rb") }
    end

    it "is part of the base: contract, manifest, Dockerfile, and probe" do
      expect(bundled).not_to be_empty
      dockerfile = RuntimeImages::CoworkerBase::DIRECTORY.join("Dockerfile").read
      bundled.each do |key|
        expect(RuntimeImages::RuntimeAbi.providers).to have_key(key), "#{key} is missing from abi.yml providers"
        expect(RuntimeImages::CoworkerBase.provider_keys).to include(key), "#{key} is missing from base.yml providers"
        expect(dockerfile).to include(RuntimeImages::RuntimeAbi.providers.fetch(key).fetch("path").delete_prefix("/usr/local/bin/")).or include(key)
        expect(described_class.expected_checks).to include("provider-#{key}", "abi-path-#{key}")
      end
    end

    it "has an absolute path and a version probe in the ABI" do
      RuntimeImages::RuntimeAbi.providers.each do |key, provider|
        expect(provider["path"]).to start_with("/"), key
        expect(provider["probe"]).to be_present, key
      end
    end

    it "only lists providers that are bundled" do
      expect(RuntimeImages::RuntimeAbi.providers.keys - bundled).to be_empty
    end
  end

  describe ".expected_checks" do
    it "covers entrypoint, every provider, identity, mounts, MCP, and confinement" do
      expect(described_class.expected_checks).to include(
        "abi-entrypoint", "identity", "provider-claude", "provider-codex", "provider-agy", "provider-muse",
        "abi-path-muse", "abi-dir-workspace", "abi-dir-coworker", "tool-git", "no-baked-credentials", "read-only-root",
        "confinement-no-new-privs", "confinement-caps-dropped", "mount-tmp-options", "mcp-socket-dir", "mcp-socket-path"
      )
    end

    it "skips only the confinement-dependent checks in build mode" do
      build = described_class.expected_checks(mode: :build)
      expect(build).to include("provider-claude", "identity")
      expect(build & described_class::CONFINEMENT_CHECKS).to be_empty
    end

    it "rejects unknown modes" do
      expect { described_class.expected_checks(mode: :loose) }.to raise_error(ArgumentError)
    end
  end

  describe ".evaluate" do
    it "accepts a complete, passing probe" do
      expect(evaluate).to be_conformant
    end

    it "fails a missing provider (not on PATH)" do
      output = full_output.sub("ok provider-agy\n", "fail provider-agy: not on PATH\n")
      result = evaluate(output, status: 1)
      expect(result.codes).to include("check_failed", "probe_failed")
      expect(result.messages).to include("provider-agy: not on PATH")
    end

    it "fails an incompatible provider whose --version fails" do
      output = full_output.sub("ok provider-codex\n", "fail provider-codex: --version failed\n")
      expect(evaluate(output, status: 1).messages).to include("provider-codex: --version failed")
    end

    it "fails a check the probe never reported, even with exit 0" do
      output = full_output.sub("ok provider-muse\n", "").sub("ok confinement-no-new-privs\n", "")
      result = evaluate(output)
      expect(result.messages).to include("probe did not report provider-muse", "probe did not report confinement-no-new-privs")
    end

    it "fails a non-zero exit even when every line is ok" do
      expect(evaluate(status: 3).codes).to eq([ "probe_failed" ])
    end

    it "fails empty and malformed output" do
      expect(evaluate("", status: 0).codes).to include("probe_no_output", "check_missing")
      expect(evaluate(full_output + "maybe fine\n").codes).to include("output_malformed")
    end

    it "does not require confinement checks in build mode" do
      output = described_class.expected_checks(mode: :build).map { |n| "ok #{n}" }.join("\n")
      expect(evaluate(output, mode: :build)).to be_conformant
      expect(evaluate(output, mode: :full).codes).to include("check_missing")
    end
  end

  describe ".evaluate! and .verify_image!" do
    let(:reference) { "registry.example/coworker-base@sha256:#{"d" * 64}" }

    it "raises with the failing checks" do
      expect { described_class.evaluate!("fail provider-agy: not on PATH\n", exit_status: 1) }
        .to raise_error(described_class::NonConformant, /provider-agy: not on PATH/)
    end

    it "runs the confined probe command against a digest-pinned image" do
      seen = nil
      result = described_class.verify_image!(reference, runner: ->(argv) { seen = argv; [ full_output, 0 ] })
      expect(result).to be_conformant
      expect(seen).to include("--read-only", "--cap-drop", "ALL", "no-new-privileges", "--network", "none", reference)
      expect(seen.join(" ")).to include("/workspace:rw", "/tmp:rw,nodev,noexec,nosuid")
    end

    it "fails base verification when the probe reports a missing provider" do
      runner = ->(_argv) { [ full_output.sub("ok provider-muse\n", "fail provider-muse: not on PATH\n"), 1 ] }
      expect { described_class.verify_image!(reference, runner: runner) }.to raise_error(described_class::NonConformant, /provider-muse/)
    end

    it "refuses an image not pinned by digest" do
      expect { described_class.verify_image!("registry.example/coworker-base:latest", runner: ->(_) { [ "", 0 ] }) }
        .to raise_error(RuntimeImages::CoworkerBase::InvalidDefinition)
    end
  end

  describe "the probe script", if: system("command -v sh >/dev/null") do
    it "is valid POSIX shell and reports identity and tools in build mode" do
      expect(system("sh", "-n", described_class::SCRIPT.to_s)).to be(true)
    end
  end
end

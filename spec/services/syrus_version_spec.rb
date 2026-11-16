require "rails_helper"

RSpec.describe SyrusVersion do
  def with_env(**vars)
    saved = vars.transform_values { |_| nil }
    saved.each_key { |key| saved[key] = ENV[key.to_s] }
    vars.each { |key, value| value.nil? ? ENV.delete(key.to_s) : ENV[key.to_s] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key.to_s) : ENV[key.to_s] = value }
  end

  describe ".release" do
    it "returns the semantic release version without changing the revision" do
      with_env(SYRUS_VERSION: "v1.2.3", GIT_SHA: "abc123") do
        expect(described_class.release).to eq(Gem::Version.new("1.2.3"))
        expect(described_class.current).to eq("abc123")
        expect(described_class.description).to eq("v1.2.3")
      end
    end

    it "is unknown for empty or malformed values" do
      [ "", "not-a-version" ].each do |value|
        with_env(SYRUS_VERSION: value) { expect(described_class.release).to be_nil }
      end
    end

    it "uses the baked full build description when present" do
      with_env(SYRUS_VERSION: "1.2.3", SYRUS_VERSION_DESCRIPTION: "1.2.3-4-gabc123") do
        expect(described_class.description).to eq("1.2.3-4-gabc123")
      end
    end
  end

  def with_process_command(program:, argv:)
    saved_program = $PROGRAM_NAME.dup
    saved_argv = ARGV.dup
    $PROGRAM_NAME = program
    ARGV.replace(argv)
    yield
  ensure
    $PROGRAM_NAME = saved_program
    ARGV.replace(saved_argv)
  end

  describe ".sidecar_process?" do
    it "detects run and chat MCP sidecars" do
      with_env(SYRUS_MCP_SIDECAR: "1", SYRUS_CHAT_MCP_SIDECAR: nil) do
        expect(described_class.sidecar_process?).to be(true)
      end

      with_env(SYRUS_MCP_SIDECAR: nil, SYRUS_CHAT_MCP_SIDECAR: "1") do
        expect(described_class.sidecar_process?).to be(true)
      end
    end
  end

  describe ".server_process?" do
    before do
      production_env = ActiveSupport::StringInquirer.new("production")
      allow(Rails).to receive(:env).and_return(production_env)
    end

    it "tracks normal web and worker commands" do
      with_env(SYRUS_ROLE: "worker", SYRUS_MCP_SIDECAR: nil, SYRUS_CHAT_MCP_SIDECAR: nil) do
        with_process_command(program: "bin/jobs", argv: []) do
          expect(described_class.server_process?).to be(true)
        end

        with_process_command(program: "bin/rails", argv: [ "server" ]) do
          expect(described_class.server_process?).to be(true)
        end
      end
    end

    it "does not track ad hoc Rails commands even when they inherit SYRUS_ROLE" do
      with_env(SYRUS_ROLE: "worker", SYRUS_MCP_SIDECAR: nil, SYRUS_CHAT_MCP_SIDECAR: nil) do
        with_process_command(program: "bin/rails", argv: [ "runner", "puts :ok" ]) do
          expect(described_class.server_process?).to be(false)
        end

        with_process_command(program: "bin/rails", argv: [ "db:prepare" ]) do
          expect(described_class.server_process?).to be(false)
        end
      end
    end

    it "does not track MCP sidecars even when they inherit SYRUS_ROLE" do
      with_env(SYRUS_ROLE: "worker", SYRUS_MCP_SIDECAR: "1", SYRUS_CHAT_MCP_SIDECAR: nil) do
        with_process_command(program: "bin/jobs", argv: []) do
          expect(described_class.server_process?).to be(false)
        end
      end
    end
  end
end

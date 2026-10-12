require "rails_helper"

RSpec.describe ChatAgentActivity do
  let(:now) { Time.zone.parse("2026-10-01 12:00:00 UTC") }
  let(:stat) { instance_double(File::Stat, mtime: now - 3.seconds, size: 1234) }

  def jsonl(*records)
    records.map(&:to_json).join("\n") + "\n"
  end

  describe ".extract" do
    it "extracts an in-flight Claude tool use" do
      activity = described_class.extract(
        provider: "claude",
        now: now,
        stat: stat,
        jsonl: jsonl(
          {
            "timestamp" => "2026-10-01T11:59:50Z",
            "message" => {
              "content" => [
                { "type" => "tool_use", "id" => "toolu_1", "name" => "Bash" }
              ]
            }
          }
        )
      )

      expect(activity.label).to eq("running commands")
      expect(activity.raw_name).to eq("Bash")
      expect(activity.elapsed_seconds).to eq(10)
      expect(activity.idle_seconds).to eq(3)
    end

    it "does not report a paired Claude tool use as in flight" do
      activity = described_class.extract(
        provider: "claude",
        now: now,
        stat: stat,
        jsonl: jsonl(
          {
            "timestamp" => "2026-10-01T11:59:50Z",
            "message" => { "content" => [ { "type" => "tool_use", "id" => "toolu_1", "name" => "Bash" } ] }
          },
          {
            "timestamp" => "2026-10-01T11:59:55Z",
            "message" => { "content" => [ { "type" => "tool_result", "tool_use_id" => "toolu_1" } ] }
          }
        )
      )

      expect(activity).to be_nil
    end

    it "extracts an in-flight Codex function call" do
      activity = described_class.extract(
        provider: "codex",
        now: now,
        stat: stat,
        jsonl: jsonl(
          {
            "timestamp" => "2026-10-01T11:59:40Z",
            "type" => "response_item",
            "payload" => {
              "type" => "function_call",
              "namespace" => "mcp__syrus_mcp_sidecar",
              "name" => "search_jobs",
              "call_id" => "call_1"
            }
          }
        )
      )

      expect(activity.label).to eq("searching code")
      expect(activity.elapsed_seconds).to eq(20)
    end

    it "pairs Codex function call outputs" do
      activity = described_class.extract(
        provider: "codex",
        now: now,
        stat: stat,
        jsonl: jsonl(
          {
            "timestamp" => "2026-10-01T11:59:40Z",
            "type" => "response_item",
            "payload" => { "type" => "function_call", "name" => "search_jobs", "call_id" => "call_1" }
          },
          {
            "timestamp" => "2026-10-01T11:59:41Z",
            "type" => "response_item",
            "payload" => { "type" => "function_call_output", "call_id" => "call_1", "output" => "{}" }
          }
        )
      )

      expect(activity).to be_nil
    end

    it "extracts an in-flight Muse tool batch effect" do
      activity = described_class.extract(
        provider: "muse",
        now: now,
        stat: stat,
        jsonl: jsonl(
          {
            "timestamp" => "2026-10-01T11:59:30Z",
            "payload_type" => "tool_batch.effect.started",
            "payload" => {
              "record" => {
                "call_id" => "call_1",
                "tool_name" => "exec_command"
              }
            }
          }
        )
      )

      expect(activity.label).to eq("running commands")
      expect(activity.elapsed_seconds).to eq(30)
    end

    it "pairs Muse subagent spawn results" do
      activity = described_class.extract(
        provider: "muse",
        now: now,
        stat: stat,
        jsonl: jsonl(
          {
            "timestamp" => "2026-10-01T11:59:30Z",
            "payload_type" => "subagent.control.spawn_accepted",
            "payload" => { "subagent_id" => "agent_1" }
          },
          {
            "timestamp" => "2026-10-01T11:59:50Z",
            "payload_type" => "subagent.control.result_ready",
            "payload" => { "subagent_id" => "agent_1" }
          }
        )
      )

      expect(activity).to be_nil
    end

    it "falls back to a generic label for unknown in-flight tools" do
      activity = described_class.extract(
        provider: "codex",
        now: now,
        stat: stat,
        jsonl: jsonl(
          {
            "timestamp" => "2026-10-01T11:59:45Z",
            "type" => "response_item",
            "payload" => { "type" => "function_call", "name" => "new_vendor_tool", "call_id" => "call_1" }
          }
        )
      )

      expect(activity.label).to eq("working")
    end

    it "returns no indicator for malformed tails" do
      activity = described_class.extract(
        provider: "codex",
        now: now,
        stat: stat,
        jsonl: '{"type":"response_item","payload":'
      )

      expect(activity).to be_nil
    end
  end

  describe ".for" do
    around do |example|
      Dir.mktmpdir("syrus-chat-agent-activity") do |dir|
        old_root = ENV["SYRUS_DATA_ROOT"]
        ENV["SYRUS_DATA_ROOT"] = dir
        example.run
      ensure
        ENV["SYRUS_DATA_ROOT"] = old_root
      end
    end

    it "reads only the bounded transcript tail" do
      user = Factories.user
      chat = ChatSession.create!(user: user, chat_provider: "codex", turn_in_flight: true)
      transcript_path = ChatWorkspace.agent_home_for(chat, "codex").join(
        "sessions", "2026", "10", "01", "rollout-2026-10-01T11-59-00-codex-session.jsonl"
      )
      FileUtils.mkdir_p(transcript_path.dirname)
      old_unpaired_call = jsonl(
        {
          "timestamp" => "2026-10-01T11:00:00Z",
          "type" => "response_item",
          "payload" => { "type" => "function_call", "name" => "exec_command", "call_id" => "old_call" }
        }
      )
      File.write(transcript_path, old_unpaired_call + (" " * (described_class::TAIL_BYTES + 1024)))

      activity = described_class.for(chat, now: now)

      expect(activity).to be_nil
    end
  end
end

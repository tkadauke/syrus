require "rails_helper"

RSpec.describe AgenticWaitingNoDiffDetector do
  let(:job) { Factories.job }
  let(:run) { job.initial_run }

  def jsonl(*rows)
    rows.map(&:to_json).join("\n")
  end

  def capture_transcript!(*rows)
    run.create_provider_session!(
      provider: run.agent_provider,
      session_id: "session-#{SecureRandom.hex(4)}",
      transcript_jsonl: jsonl(*rows)
    )
  end

  it "detects a no-diff run that backgrounded a command and waited for notification" do
    capture_transcript!(
      {
        "type" => "assistant",
        "message" => {
          "content" => [
            { "type" => "tool_use", "name" => "Bash", "id" => "u1", "input" => { "command" => "CI=true bin/rspec &" } }
          ]
        }
      },
      {
        "type" => "assistant",
        "message" => {
          "content" => [
            { "type" => "text", "text" => "I'll wait for the completion notification before doing anything else." }
          ]
        }
      }
    )

    expect(described_class.detect?(run)).to be(true)
  end

  it "detects a no-diff run that tries to use ScheduleWakeup for continuation" do
    capture_transcript!(
      {
        "type" => "assistant",
        "message" => {
          "content" => [
            { "type" => "text", "text" => "I used ScheduleWakeup so the next turn can check the tests." }
          ]
        }
      }
    )

    expect(described_class.detect?(run)).to be(true)
  end

  it "does not flag a foreground command followed by an ordinary no-change conclusion" do
    capture_transcript!(
      {
        "type" => "assistant",
        "message" => {
          "content" => [
            { "type" => "tool_use", "name" => "Bash", "id" => "u1", "input" => { "command" => "bin/rspec spec/models/user_spec.rb" } }
          ]
        }
      },
      {
        "type" => "assistant",
        "message" => {
          "content" => [
            { "type" => "text", "text" => "The repository already has the requested behavior, so I made no edits." }
          ]
        }
      }
    )

    expect(described_class.detect?(run)).to be(false)
  end
end

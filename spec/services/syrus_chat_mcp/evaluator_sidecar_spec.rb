require "rails_helper"
require Rails.root.join("app/services/syrus_chat_mcp/sidecar")

RSpec.describe SyrusChatMcp::EvaluatorSidecar do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, chat_provider: "claude") }

  it "exposes only read-only chat tools to disposable evaluators" do
    names = described_class.tool_names(chat_session)

    expect(names).to include("read_job", "read_chat_messages", "search_jobs")
    expect(names).not_to include(
      "propose_job",
      "approve_job",
      "write_memory",
      "delete_memory",
      "schedule_wakeup",
      "submit_coding_changes",
      "draw_shape",
      "update_scene"
    )
  end
end

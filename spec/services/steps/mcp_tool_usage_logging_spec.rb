require "rails_helper"

RSpec.describe Steps::Base do
  it "records workflow MCP tool usage from the buffered agent log sink" do
    run = Factories.job.initial_run
    handler = described_class.new(run)
    sink, flush = handler.send(:buffered_log_sink)

    sink.call("tool started", kind: "tool_call",
                              tool_name: "syrus-mcp-sidecar.read_live_state",
                              tool_input: { "detail" => "compact" },
                              tool_use_id: "call_1")
    sink.call("tool finished", kind: "tool_result",
                               tool_result_content: { "ok" => true },
                               tool_result_error: false,
                               tool_use_id: "call_1")
    flush.call

    usage = McpToolUsage.sole
    expect(usage).to have_attributes(
      surface: "workflow",
      normalized_tool_name: "read_live_state",
      status: "completed",
      run_id: run.id
    )
    expect(run.job_logs.pluck(:kind)).to eq(%w[tool_call tool_result])
  end
end

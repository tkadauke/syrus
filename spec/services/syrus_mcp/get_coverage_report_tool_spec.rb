require "rails_helper"

RSpec.describe SyrusMcp::GetCoverageReportTool do
  let(:run) { Factories.job.initial_run }

  def server_for(run)
    MCP::Server.new(
      name: "syrus-mcp-sidecar",
      tools: [ SyrusMcp::GetCoverageReportTool ],
      server_context: { run_id: run.id }
    )
  end

  def jsonrpc(server, method, id: 1, params: {})
    request = { jsonrpc: "2.0", id: id, method: method, params: params }.to_json
    raw = server.handle_json(request)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(run)
    jsonrpc(server_for(run), "tools/call", params: {
      name: "get_coverage_report",
      arguments: {}
    })
  end

  it "returns coverage_unavailable when no coverage artifact exists" do
    response = call_tool(run)

    expect(response[:result][:isError]).to be_falsey
    payload = JSON.parse(response[:result][:content].first[:text])
    expect(payload).to eq("coverage_unavailable" => true)
  end

  it "returns the coverage artifact fields when coverage has been collected" do
    artifact = {
      "summary"          => { "lines_pct" => 87.3, "branches_pct" => 72.1 },
      "files"            => { "app/models/user.rb" => { "lines_pct" => 91.0, "branches_pct" => 80.0 } },
      "diff_annotations" => { "app/models/user.rb" => { "5" => "covered", "10" => "uncovered" } },
      "pr_delta"         => { "covered" => 8, "total" => 10, "pct" => 80.0, "uncovered_files" => [] },
      "threshold_miss"   => false,
      "sources_status"   => [ { "artifact" => "coverage/lcov.info", "found" => true, "lines_pct" => 87.3 } ]
    }
    Workflow::CoverageArtifact.write!(run.workflow, artifact)

    response = call_tool(run)

    expect(response[:result][:isError]).to be_falsey
    payload = JSON.parse(response[:result][:content].first[:text])
    expect(payload["summary"]).to eq("lines_pct" => 87.3, "branches_pct" => 72.1)
    expect(payload["files"]).to eq("app/models/user.rb" => { "lines_pct" => 91.0, "branches_pct" => 80.0 })
    expect(payload["diff_annotations"]).to eq("app/models/user.rb" => { "5" => "covered", "10" => "uncovered" })
    expect(payload["pr_delta"]).to include("covered" => 8, "total" => 10, "pct" => 80.0)
    expect(payload["threshold_miss"]).to eq(false)
    expect(payload["sources_status"]).to eq([ { "artifact" => "coverage/lcov.info", "found" => true, "lines_pct" => 87.3 } ])
    expect(payload).not_to have_key("coverage_unavailable")
  end

  it "does not expose hit_map_attached in the response" do
    artifact = {
      "summary"          => { "lines_pct" => 80.0 },
      "threshold_miss"   => false,
      "hit_map_attached" => true
    }
    Workflow::CoverageArtifact.write!(run.workflow, artifact)

    response = call_tool(run)

    payload = JSON.parse(response[:result][:content].first[:text])
    expect(payload).not_to have_key("hit_map_attached")
  end
end

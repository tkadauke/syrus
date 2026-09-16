require "rails_helper"
require "base64"

RSpec.describe "SyrusMcp artifact round trip" do
  let(:run) { Factories.job.initial_run }
  let(:png_bytes) { "\x89PNG\r\n\x1a\n".b }
  let(:png_base64) { Base64.strict_encode64(png_bytes) }

  def payload_from(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "lets the same Run list and read back an artifact it just submitted" do
    submit_response = SyrusMcp::SubmitVisualArtifactTool.call(
      type: "visual_review_screenshot",
      title: "Homepage after fix",
      image_base64: png_base64,
      server_context: { run: run }
    )
    expect(submit_response).not_to be_error

    list_response = SyrusMcp::ListArtifactsTool.call(workflow_id: run.workflow_id, server_context: { run: run })
    artifacts = payload_from(list_response)[:artifacts]
    expect(artifacts.size).to eq(1)
    expect(artifacts.first).to include(title: "Homepage after fix")

    read_response = SyrusMcp::ReadArtifactTool.call(workflow_id: run.workflow_id, type: artifacts.first[:type], server_context: { run: run })
    expect(read_response).not_to be_error
    expect(Base64.strict_decode64(read_response.content.first[:data])).to eq(png_bytes)
  end

  it "lets a later Run on the same Workflow list and read an artifact submitted by an earlier Run" do
    submit_response = SyrusMcp::SubmitVisualArtifactTool.call(
      type: "visual_review_screenshot",
      title: "Homepage after fix",
      image_base64: png_base64,
      server_context: { run: run }
    )
    expect(submit_response).not_to be_error

    later_step = run.workflow.steps.create!(kind: "summarize", position: run.step.position + 1)
    later_run = later_step.runs.create!(job: run.job, trigger_kind: run.trigger_kind, state: "queued")

    list_response = SyrusMcp::ListArtifactsTool.call(workflow_id: run.workflow_id, server_context: { run: later_run })
    artifacts = payload_from(list_response)[:artifacts]
    expect(artifacts.size).to eq(1)
    stored_type = artifacts.first[:type]

    read_response = SyrusMcp::ReadArtifactTool.call(workflow_id: run.workflow_id, type: stored_type, server_context: { run: later_run })
    expect(read_response).not_to be_error
    expect(Base64.strict_decode64(read_response.content.first[:data])).to eq(png_bytes)
  end
end

require "rails_helper"
require "base64"

RSpec.describe SyrusMcp::ReadArtifactTool do
  let(:run) { Factories.job.initial_run }
  let(:png_bytes) { "\x89PNG\r\n\x1a\n".b }
  let(:png_base64) { Base64.strict_encode64(png_bytes) }

  def submit_screenshot(type: "visual_review_screenshot", title: "Homepage after fix", image_base64: png_base64, content_type: nil, target_run: run)
    SyrusMcp::SubmitVisualArtifactTool.call(
      type: type, title: title, image_base64: image_base64, content_type: content_type, server_context: { run: target_run }
    )
    target_run.workflow.reload.artifact("typed_artifacts").first["type"]
  end

  it "returns the stored image bytes as MCP image content" do
    stored_type = submit_screenshot

    response = described_class.call(workflow_id: run.workflow_id, type: stored_type, server_context: { run: run })

    expect(response).not_to be_error
    image_content = response.content.first
    expect(image_content[:type]).to eq("image")
    expect(image_content[:mimeType]).to eq("image/png")
    expect(Base64.strict_decode64(image_content[:data])).to eq(png_bytes)
  end

  it "accepts a run_id-only sidecar context" do
    stored_type = submit_screenshot

    response = described_class.call(workflow_id: run.workflow_id, type: stored_type, server_context: { run_id: run.id })

    expect(response).not_to be_error
  end

  it "reflects the stored content type" do
    stored_type = submit_screenshot(content_type: "image/jpeg")

    response = described_class.call(workflow_id: run.workflow_id, type: stored_type, server_context: { run: run })

    expect(response.content.first[:mimeType]).to eq("image/jpeg")
  end

  it "rejects an unknown artifact type" do
    response = described_class.call(workflow_id: run.workflow_id, type: "no_such_type", server_context: { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("no image artifact found")
  end

  it "rejects a blank type" do
    response = described_class.call(workflow_id: run.workflow_id, type: "  ", server_context: { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("type is required")
  end

  it "rejects a workflow belonging to a different repository" do
    other_job = Factories.job(repository: Factories.repository(user: run.job.user))
    stored_type = submit_screenshot(target_run: other_job.initial_run)

    response = described_class.call(workflow_id: other_job.initial_run.workflow_id, type: stored_type, server_context: { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("outside this repository scope")
  end

  it "exposes the expected tool name and required schema fields" do
    expect(described_class.tool_name).to eq("read_artifact")
    expect(described_class.input_schema_value.to_h[:required]).to contain_exactly("workflow_id", "type")
  end
end

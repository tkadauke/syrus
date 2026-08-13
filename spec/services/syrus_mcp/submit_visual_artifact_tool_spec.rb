require "rails_helper"
require "base64"

RSpec.describe SyrusMcp::SubmitVisualArtifactTool do
  let(:run) { Factories.job.initial_run }
  let(:png_bytes) { "\x89PNG\r\n\x1a\n".b }
  let(:png_base64) { Base64.strict_encode64(png_bytes) }

  def call(
    type: "visual_review_screenshot",
    title: "Homepage after fix",
    image_base64: png_base64,
    content_type: nil,
    server_context: { run: run }
  )
    described_class.call(type: type, title: title, image_base64: image_base64, content_type: content_type, server_context: server_context)
  end

  it "accepts a run_id-only sidecar context" do
    described_class.call(
      type: "visual_review_screenshot",
      title: "Homepage after fix",
      image_base64: png_base64,
      content_type: nil,
      server_context: { run_id: run.id }
    )

    entries = run.workflow.reload.artifact("typed_artifacts")
    expect(entries.size).to eq(1)
    expect(entries.first).to include("type" => "visual_review_screenshot", "title" => "Homepage after fix")
  end

  it "attaches the decoded image bytes to the workflow" do
    call

    attachment = run.workflow.reload.visual_artifact_for("visual_review_screenshot")
    expect(attachment).to be_present
    expect(attachment.download).to eq(png_bytes)
    expect(attachment.content_type).to eq("image/png")
  end

  it "writes a typed_artifacts entry pointing at the stored image" do
    call

    entries = run.workflow.reload.artifact("typed_artifacts")
    expect(entries.size).to eq(1)
    entry = entries.first
    expect(entry).to include("type" => "visual_review_screenshot", "title" => "Homepage after fix")
    expect(entry["payload"]).to include(
      "content_type" => "image/png",
      "byte_size"    => png_bytes.bytesize
    )
    expect(entry["payload"]["image_url"]).to eq(
      "/api/v1/app/workflows/#{run.workflow.id}/visual_artifact?type=visual_review_screenshot"
    )
    expect(entry["created_at"]).to be_present
  end

  it "defaults content_type to image/png when omitted" do
    call(content_type: nil)

    attachment = run.workflow.reload.visual_artifact_for("visual_review_screenshot")
    expect(attachment.content_type).to eq("image/png")
  end

  it "accepts image/jpeg and image/webp content types" do
    call(content_type: "image/jpeg")
    expect(run.workflow.reload.visual_artifact_for("visual_review_screenshot").content_type).to eq("image/jpeg")
  end

  it "replaces the entry and purges the previous blob when called again with the same type" do
    call(title: "First shot")
    first_attachment = run.workflow.reload.visual_artifact_for("visual_review_screenshot")
    first_blob_id = first_attachment.blob.id

    call(title: "Second shot")

    workflow = run.workflow.reload
    entries = workflow.artifact("typed_artifacts")
    expect(entries.size).to eq(1)
    expect(entries.first["title"]).to eq("Second shot")
    expect(workflow.visual_artifacts.count).to eq(1)
    expect(ActiveStorage::Blob.exists?(first_blob_id)).to be(false)
  end

  it "accumulates entries with different types" do
    call(type: "home_screenshot", title: "Home")
    call(type: "login_screenshot", title: "Login")

    entries = run.workflow.reload.artifact("typed_artifacts")
    expect(entries.map { |e| e["type"] }).to contain_exactly("home_screenshot", "login_screenshot")
    expect(run.workflow.visual_artifacts.count).to eq(2)
  end

  it "rejects an empty type" do
    response = call(type: "  ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("type is required")
    expect(run.workflow.reload.artifact("typed_artifacts")).to be_nil
  end

  it "rejects an empty title" do
    response = call(title: "  ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("title is required")
  end

  it "rejects an unsupported content_type" do
    response = call(content_type: "image/svg+xml")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("content_type must be one of")
    expect(run.workflow.reload.artifact("typed_artifacts")).to be_nil
  end

  it "rejects malformed base64" do
    response = call(image_base64: "not base64 at all!!! ###")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not valid base64")
  end

  it "rejects empty image data" do
    response = call(image_base64: "")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("image_base64 is empty")
  end

  it "rejects an image exceeding the maximum size" do
    huge = Base64.strict_encode64("x" * (described_class::MAX_IMAGE_BYTES + 1))

    response = call(image_base64: huge)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("exceeds maximum size")
    expect(run.workflow.reload.artifact("typed_artifacts")).to be_nil
  end

  it "writes a JobLog audit line" do
    expect { call }.to change { run.job_logs.count }.by(1)
    expect(run.job_logs.last.chunk).to include("[mcp] submit_visual_artifact: \"visual_review_screenshot\"")
  end

  it "denies the call for the adversarial_reviewer role" do
    run.step.update_columns(kind: "adversarial_review")

    response = call(server_context: { run: run.reload })

    expect(response).to be_error
    expect(run.workflow.reload.artifact("typed_artifacts")).to be_nil
  end

  it "exposes the expected tool name and required schema fields" do
    expect(described_class.tool_name).to eq("submit_visual_artifact")
    expect(described_class.input_schema_value.to_h[:required]).to contain_exactly("type", "title", "image_base64")
  end
end

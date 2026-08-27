require "rails_helper"
require "base64"
require "fileutils"

RSpec.describe SyrusMcp::SubmitVisualArtifactTool do
  let(:run) { Factories.job.initial_run }
  let(:png_bytes) { "\x89PNG\r\n\x1a\n".b }
  let(:png_base64) { Base64.strict_encode64(png_bytes) }

  def call(
    type: "visual_review_screenshot",
    title: "Homepage after fix",
    image_base64: png_base64,
    image_path: nil,
    content_type: nil,
    server_context: { run: run }
  )
    described_class.call(type: type, title: title, image_base64: image_base64, image_path: image_path, content_type: content_type, server_context: server_context)
  end

  def write_workspace_file(relative_path, bytes = png_bytes)
    path = WorkflowWorkspace.path_for(run.workflow).join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.binwrite(bytes)
    path
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
    expect(entries.first).to include("original_type" => "visual_review_screenshot", "title" => "Homepage after fix", "renderer_type" => "image_diff")
    expect(entries.first["type"]).to match(/\Avisual_review_screenshot_run_#{run.id}_1\z/)
  end

  it "attaches the decoded image bytes to the workflow" do
    call

    stored_type = run.workflow.reload.artifact("typed_artifacts").first["type"]
    attachment = run.workflow.visual_artifact_for(stored_type)
    expect(attachment).to be_present
    expect(attachment.download).to eq(png_bytes)
    expect(attachment.content_type).to eq("image/png")
  end

  it "attaches image bytes directly from a workflow-local file path" do
    write_workspace_file(".playwright-mcp/page.png")

    described_class.call(
      type: "visual_review_screenshot",
      title: "Browser screenshot",
      image_path: ".playwright-mcp/page.png",
      server_context: { run: run }
    )

    stored_type = run.workflow.reload.artifact("typed_artifacts").first["type"]
    attachment = run.workflow.visual_artifact_for(stored_type)
    expect(attachment).to be_present
    expect(attachment.download).to eq(png_bytes)
    expect(attachment.content_type).to eq("image/png")
  end

  it "infers jpeg content type from a workflow-local file path" do
    write_workspace_file("screenshots/page.jpg")

    described_class.call(
      type: "visual_review_screenshot",
      title: "Browser screenshot",
      image_path: "screenshots/page.jpg",
      server_context: { run: run }
    )

    stored_type = run.workflow.reload.artifact("typed_artifacts").first["type"]
    expect(run.workflow.visual_artifact_for(stored_type).content_type).to eq("image/jpeg")
  end

  it "writes a typed_artifacts entry pointing at the stored image" do
    call

    entries = run.workflow.reload.artifact("typed_artifacts")
    expect(entries.size).to eq(1)
    entry = entries.first
    expect(entry).to include("original_type" => "visual_review_screenshot", "title" => "Homepage after fix", "renderer_type" => "image_diff")
    expect(entry["type"]).to match(/\Avisual_review_screenshot_run_#{run.id}_1\z/)
    expect(entry["payload"]).to include(
      "content_type" => "image/png",
      "byte_size"    => png_bytes.bytesize,
      "run_id"       => run.id,
      "step_id"      => run.step_id,
      "iteration"    => run.step.iteration,
      "original_type" => "visual_review_screenshot"
    )
    expect(entry["payload"]["image_url"]).to eq(
      "/api/v1/app/workflows/#{run.workflow.id}/visual_artifact?type=#{entry["type"]}"
    )
    expect(entry["created_at"]).to be_present
  end

  it "defaults content_type to image/png when omitted" do
    call(content_type: nil)

    stored_type = run.workflow.reload.artifact("typed_artifacts").first["type"]
    attachment = run.workflow.visual_artifact_for(stored_type)
    expect(attachment.content_type).to eq("image/png")
  end

  it "accepts image/jpeg and image/webp content types" do
    call(content_type: "image/jpeg")
    stored_type = run.workflow.reload.artifact("typed_artifacts").first["type"]
    expect(run.workflow.visual_artifact_for(stored_type).content_type).to eq("image/jpeg")
  end

  it "keeps each screenshot from the same run instead of replacing earlier evidence" do
    call(title: "First shot")
    first_entry = run.workflow.reload.artifact("typed_artifacts").first
    first_blob_id = run.workflow.visual_artifact_for(first_entry["type"]).blob.id

    call(title: "Second shot")

    workflow = run.workflow.reload
    entries = workflow.artifact("typed_artifacts")
    expect(entries.size).to eq(2)
    expect(entries.map { |entry| entry["title"] }).to eq([ "First shot", "Second shot" ])
    expect(entries.map { |entry| entry["type"] }).to eq([
      "visual_review_screenshot_run_#{run.id}_1",
      "visual_review_screenshot_run_#{run.id}_2"
    ])
    expect(workflow.visual_artifacts.count).to eq(2)
    expect(ActiveStorage::Blob.exists?(first_blob_id)).to be(true)
  end

  it "accumulates entries with different types" do
    call(type: "home_screenshot", title: "Home")
    call(type: "login_screenshot", title: "Login")

    entries = run.workflow.reload.artifact("typed_artifacts")
    expect(entries.map { |e| e["original_type"] }).to contain_exactly("home_screenshot", "login_screenshot")
    expect(entries.map { |e| e["type"] }).to contain_exactly(
      "home_screenshot_run_#{run.id}_1",
      "login_screenshot_run_#{run.id}_1"
    )
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
    expect(response.content.first[:text]).to include("image_path or image_base64 is required")
  end

  it "rejects calls that provide both image_base64 and image_path" do
    write_workspace_file(".playwright-mcp/page.png")

    response = call(image_path: ".playwright-mcp/page.png")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("provide exactly one")
  end

  it "rejects image paths outside the workflow workspace" do
    response = described_class.call(
      type: "visual_review_screenshot",
      title: "Outside",
      image_path: "/etc/hosts",
      server_context: { run: run }
    )

    expect(response).to be_error
    expect(response.content.first[:text]).to include("inside the workflow workspace")
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
    expect(described_class.input_schema_value.to_h[:required]).to contain_exactly("type", "title")
  end
end

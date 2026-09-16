require "rails_helper"
require "base64"

RSpec.describe SyrusMcp::ListArtifactsTool do
  let(:run) { Factories.job.initial_run }
  let(:png_bytes) { "\x89PNG\r\n\x1a\n".b }
  let(:png_base64) { Base64.strict_encode64(png_bytes) }

  def payload_from(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "returns an empty list for a workflow with no typed artifacts" do
    response = described_class.call(workflow_id: run.workflow_id, server_context: { run: run })

    expect(response).not_to be_error
    expect(payload_from(response)).to eq(workflow_id: run.workflow_id, artifacts: [])
  end

  it "accepts a run_id-only sidecar context" do
    response = described_class.call(workflow_id: run.workflow_id, server_context: { run_id: run.id })

    expect(response).not_to be_error
    expect(payload_from(response)[:workflow_id]).to eq(run.workflow_id)
  end

  it "lists a visual artifact submitted via submit_visual_artifact, including image fields" do
    SyrusMcp::SubmitVisualArtifactTool.call(
      type: "visual_review_screenshot",
      title: "Homepage after fix",
      image_base64: png_base64,
      server_context: { run: run }
    )

    response = described_class.call(workflow_id: run.workflow_id, server_context: { run: run })
    artifacts = payload_from(response)[:artifacts]

    expect(artifacts.size).to eq(1)
    expect(artifacts.first).to include(
      title: "Homepage after fix",
      content_type: "image/png",
      byte_size: png_bytes.bytesize,
      run_id: run.id,
      step_id: run.step_id,
      iteration: run.step.iteration
    )
    expect(artifacts.first[:type]).to match(/\Avisual_review_screenshot_run_#{run.id}_1\z/)
    expect(artifacts.first[:image_url]).to eq(
      "/api/v1/app/workflows/#{run.workflow_id}/visual_artifact?type=#{artifacts.first[:type]}"
    )
  end

  it "lists a non-visual typed artifact submitted via submit_artifact without image-only fields" do
    SyrusMcp::SubmitArtifactTool.call(
      type: "rails_schema_erd",
      title: "Schema ERD",
      payload: { "tables" => [] },
      server_context: { run: run }
    )

    response = described_class.call(workflow_id: run.workflow_id, server_context: { run: run })
    artifacts = payload_from(response)[:artifacts]

    expect(artifacts).to eq([ {
      type: "rails_schema_erd",
      title: "Schema ERD",
      content_type: nil,
      byte_size: nil,
      run_id: run.id,
      step_id: run.step_id,
      iteration: nil,
      image_url: nil
    } ])
  end

  it "lists multiple artifacts in submission order" do
    SyrusMcp::SubmitVisualArtifactTool.call(type: "first", title: "First", image_base64: png_base64, server_context: { run: run })
    SyrusMcp::SubmitVisualArtifactTool.call(type: "second", title: "Second", image_base64: png_base64, server_context: { run: run })

    response = described_class.call(workflow_id: run.workflow_id, server_context: { run: run })
    artifacts = payload_from(response)[:artifacts]

    expect(artifacts.map { |a| a[:title] }).to eq([ "First", "Second" ])
  end

  it "rejects a workflow belonging to a different repository" do
    other_job = Factories.job(repository: Factories.repository(user: run.job.user))

    response = described_class.call(workflow_id: other_job.latest_workflow.id, server_context: { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("outside this repository scope")
  end

  it "rejects a workflow belonging to a different user" do
    other_job = Factories.job(repository: Factories.repository(user: Factories.user))

    response = described_class.call(workflow_id: other_job.latest_workflow.id, server_context: { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("outside this repository scope")
  end

  it "rejects a nonexistent workflow_id" do
    response = described_class.call(workflow_id: 0, server_context: { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("outside this repository scope")
  end

  it "exposes the expected tool name and required schema fields" do
    expect(described_class.tool_name).to eq("list_artifacts")
    expect(described_class.input_schema_value.to_h[:required]).to contain_exactly("workflow_id")
  end
end

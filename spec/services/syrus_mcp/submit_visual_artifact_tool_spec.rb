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
    capture_current_browser: false,
    subject: nil,
    minimum_subject_visible_fraction: described_class::DEFAULT_MINIMUM_SUBJECT_VISIBLE_FRACTION,
    content_type: nil,
    server_context: { run: run }
  )
    described_class.call(type: type, title: title, image_base64: image_base64, image_path: image_path, capture_current_browser: capture_current_browser, subject: subject, minimum_subject_visible_fraction: minimum_subject_visible_fraction, content_type: content_type, server_context: server_context)
  end

  def write_workspace_file(relative_path, bytes = png_bytes)
    path = WorkflowWorkspace.path_for(run.workflow).join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.binwrite(bytes)
    path
  end

  def stub_current_browser_capture(target_run: run, encoded_png: png_base64, page: {})
    page = {
      url: "http://127.0.0.1:3000/credential_store",
      path: "/credential_store",
      title: "Credential store",
      viewport: { width: 1440, height: 900, deviceScaleFactor: 1 }
    }.merge(page)
    fake_tool_set = Class.new do
      define_singleton_method(:available_for?) { |_repository| true }
      define_singleton_method(:tool_definitions) do
        [
          { name: "browser_screenshot", description: "Screenshot", input_schema: {} },
          { name: "browser_evaluate", description: "Evaluate", input_schema: {} }
        ]
      end

      define_method(:handle) do |tool_name, params, server_context|
        raise "wrong run context" unless server_context[:run] == target_run

        case tool_name
        when "browser_screenshot"
          MCP::Tool::Response.new([ { type: "image", data: encoded_png, mimeType: "image/png" } ])
        when "browser_evaluate"
          raise "wrong evaluate function" unless params.fetch("function").include?("window.location.href")

          MCP::Tool::Response.new([
            {
              type: "text",
              text: <<~TEXT
                ### Result
                #{page.to_json}
                ### Ran Playwright code
                ```js
                () => ({ url: window.location.href })
                ```
              TEXT
            }
          ])
        else
          MCP::Tool::Response.new([ { type: "text", text: "Error: unexpected tool" } ], error: true)
        end
      end
    end

    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:mcp_tool_set).and_return([ fake_tool_set ])
  end

  def subject_evaluate_response(rect:, viewport: { width: 1440, height: 900 }, scroll_position: { x: 0, y: 200 })
    MCP::Tool::Response.new([
      {
        type: "text",
        text: {
          rect: rect,
          viewport: viewport,
          scrollPosition: scroll_position
        }.to_json
      }
    ])
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

  it "echoes the resolved artifact type back in the response so it can be referenced from submit_report" do
    response = call

    stored_type = run.workflow.reload.artifact("typed_artifacts").first["type"]
    expect(response.content.first[:text]).to include(stored_type)
    expect(response.content.first[:text]).to include("submit_report")
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
      "original_type" => "visual_review_screenshot",
      "source" => "base64"
    )
    expect(entry["payload"]["captured_at"]).to be_present
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
    expect(response.content.first[:text]).to include("image_base64 is empty")
  end

  it "rejects calls that provide both image_base64 and image_path" do
    write_workspace_file(".playwright-mcp/page.png")

    response = call(image_path: ".playwright-mcp/page.png")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("provide exactly one")
  end

  it "captures the current MCP browser directly and stores page provenance" do
    stub_current_browser_capture

    response = described_class.call(
      type: "visual_review_screenshot",
      title: "Credential store desktop",
      capture_current_browser: true,
      server_context: { run: run }
    )

    expect(response).not_to be_error
    entry = run.workflow.reload.artifact("typed_artifacts").first
    expect(entry["payload"]).to include(
      "source" => "current_browser",
      "page" => {
        "url" => "http://127.0.0.1:3000/credential_store",
        "path" => "/credential_store",
        "title" => "Credential store"
      },
      "viewport" => {
        "width" => 1440,
        "height" => 900,
        "device_scale_factor" => 1
      }
    )
    expect(entry["payload"]["captured_at"]).to be_present
    stored_type = entry.fetch("type")
    expect(run.workflow.visual_artifact_for(stored_type).download).to eq(png_bytes)
  end

  it "defaults omitted image inputs to current-browser capture and stores provenance" do
    stub_current_browser_capture(
      page: {
        url: "http://127.0.0.1:3000/jobs/42",
        path: "/jobs/42",
        title: "Job detail",
        viewport: { width: 390, height: 844, deviceScaleFactor: 3 }
      }
    )

    response = described_class.call(
      type: "visual_review_screenshot",
      title: "Job detail mobile",
      server_context: { run: run }
    )

    expect(response).not_to be_error
    entry = run.workflow.reload.artifact("typed_artifacts").first
    expect(entry["payload"]).to include(
      "source" => "current_browser",
      "page" => {
        "url" => "http://127.0.0.1:3000/jobs/42",
        "path" => "/jobs/42",
        "title" => "Job detail"
      },
      "viewport" => {
        "width" => 390,
        "height" => 844,
        "device_scale_factor" => 3
      }
    )
    expect(run.workflow.visual_artifact_for(entry.fetch("type")).download).to eq(png_bytes)
  end

  it "scrolls a selector subject into view before capturing the current browser" do
    evaluate_response = subject_evaluate_response(rect: { x: 10, y: 20, width: 300, height: 80 })
    screenshot_response = MCP::Tool::Response.new([ { type: "image", data: png_base64, mimeType: "image/png" } ])
    calls = []
    allow(described_class).to receive(:call_browser_tool) do |_run, tool_name, params|
      calls << tool_name
      if tool_name == "browser_evaluate" && params.fetch("function").include?("document.querySelector")
        expect(params.fetch("function")).to include(%([data-testid=design-docs]))
        evaluate_response
      elsif tool_name == "browser_screenshot"
        screenshot_response
      else
        MCP::Tool::Response.new([ { type: "text", text: "{}" } ])
      end
    end

    response = described_class.call(
      type: "visual_review_screenshot", title: "Design docs", subject: "[data-testid=design-docs]", server_context: { run: run }
    )

    expect(response).not_to be_error
    expect(calls.first(2)).to eq(%w[browser_evaluate browser_screenshot])
  end

  it "rejects a subject below the default visible-area threshold without capturing or storing an artifact" do
    evaluate_response = subject_evaluate_response(rect: { x: 0, y: 850, width: 300, height: 200 })
    allow(described_class).to receive(:call_browser_tool).and_return(evaluate_response)

    response = described_class.call(
      type: "visual_review_screenshot", title: "Cut off card", subject: "#card", server_context: { run: run }
    )

    expect(response).to be_error
    expect(response.content.first[:text]).to include('subject "#card" is only 25% visible; scroll or resize and retry')
    expect(described_class).not_to have_received(:call_browser_tool).with(run, "browser_screenshot", anything)
    expect(run.workflow.reload.artifact("typed_artifacts")).to be_nil
    expect(run.workflow.visual_artifacts).to be_empty
  end

  it "accepts a partially visible subject at a configured threshold" do
    evaluate_response = subject_evaluate_response(rect: { x: 0, y: 850, width: 300, height: 200 })
    screenshot_response = MCP::Tool::Response.new([ { type: "image", data: png_base64, mimeType: "image/png" } ])
    allow(described_class).to receive(:call_browser_tool).and_return(
      evaluate_response,
      screenshot_response,
      MCP::Tool::Response.new([ { type: "text", text: "{}" } ])
    )

    response = described_class.call(
      type: "visual_review_screenshot", title: "Cut off card", subject: "#card",
      minimum_subject_visible_fraction: 0.2, server_context: { run: run }
    )

    expect(response).not_to be_error
  end

  it "accepts a subject taller than the viewport when its top edge is visible" do
    evaluate_response = subject_evaluate_response(rect: { x: 20, y: 10, width: 400, height: 1800 })
    screenshot_response = MCP::Tool::Response.new([ { type: "image", data: png_base64, mimeType: "image/png" } ])
    allow(described_class).to receive(:call_browser_tool).and_return(
      evaluate_response,
      screenshot_response,
      MCP::Tool::Response.new([ { type: "text", text: "{}" } ])
    )

    response = described_class.call(
      type: "visual_review_screenshot", title: "Long panel", subject: "#panel", server_context: { run: run }
    )

    expect(response).not_to be_error
    expect(run.workflow.reload.artifact("typed_artifacts").first.dig("payload", "subject_visible_fraction")).to eq(0.4944)
  end

  it "rejects a taller-than-viewport subject when its top edge is above the viewport" do
    evaluate_response = subject_evaluate_response(rect: { x: 20, y: -10, width: 400, height: 1800 })
    allow(described_class).to receive(:call_browser_tool).and_return(evaluate_response)

    response = described_class.call(
      type: "visual_review_screenshot", title: "Long panel", subject: "#panel", server_context: { run: run }
    )

    expect(response).to be_error
    expect(response.content.first[:text]).to include("scroll or resize and retry")
    expect(run.workflow.reload.artifact("typed_artifacts")).to be_nil
  end

  it "stores subject visibility and scroll provenance" do
    evaluate_response = subject_evaluate_response(
      rect: { x: 10, y: 20, width: 300, height: 80 },
      viewport: { width: 390, height: 844 },
      scroll_position: { x: 4, y: 512 }
    )
    screenshot_response = MCP::Tool::Response.new([ { type: "image", data: png_base64, mimeType: "image/png" } ])
    allow(described_class).to receive(:call_browser_tool).and_return(
      evaluate_response,
      screenshot_response,
      MCP::Tool::Response.new([ { type: "text", text: "{}" } ])
    )

    response = described_class.call(
      type: "visual_review_screenshot", title: "Card", subject: "#card", server_context: { run: run }
    )

    expect(response).not_to be_error
    expect(run.workflow.reload.artifact("typed_artifacts").first.fetch("payload")).to include(
      "subject" => "#card",
      "subject_visible_fraction" => 1.0,
      "subject_rect" => { "x" => 10, "y" => 20, "width" => 300, "height" => 80 },
      "scroll_position" => { "x" => 4, "y" => 512 }
    )
  end

  it "resolves a browser_snapshot ref while scrolling before capturing" do
    evaluate_response = subject_evaluate_response(rect: { x: 0, y: 100, width: 240, height: 60 })
    screenshot_response = MCP::Tool::Response.new([ { type: "image", data: png_base64, mimeType: "image/png" } ])
    allow(described_class).to receive(:call_browser_tool).and_return(evaluate_response, screenshot_response, MCP::Tool::Response.new([ { type: "text", text: "{}" } ]))

    response = described_class.call(
      type: "visual_review_screenshot", title: "Card", subject: "e12", server_context: { run: run }
    )

    expect(response).not_to be_error
    expect(described_class).to have_received(:call_browser_tool).with(
      run, "browser_evaluate", hash_including("target" => "e12", "element" => "visual artifact subject")
    ).ordered
    expect(described_class).to have_received(:call_browser_tool).with(run, "browser_screenshot", {}).ordered
  end

  it "returns a clear error when the subject element is missing" do
    missing = MCP::Tool::Response.new([ { type: "text", text: "Error: Subject element not found or not visible: #missing" } ], error: true)
    allow(described_class).to receive(:call_browser_tool).and_return(missing)

    response = described_class.call(
      type: "visual_review_screenshot", title: "Missing", subject: "#missing", server_context: { run: run }
    )

    expect(response).to be_error
    expect(response.content.first[:text]).to include("subject could not be brought into view")
    expect(response.content.first[:text]).to include("Subject element not found or not visible: #missing")
    expect(described_class).not_to have_received(:call_browser_tool).with(run, "browser_screenshot", anything)
    expect(run.workflow.reload.artifact("typed_artifacts")).to be_nil
  end

  it "keeps omitted-subject capture unchanged" do
    screenshot_response = MCP::Tool::Response.new([ { type: "image", data: png_base64, mimeType: "image/png" } ])
    allow(described_class).to receive(:call_browser_tool).and_return(screenshot_response, MCP::Tool::Response.new([ { type: "text", text: "{}" } ]))

    response = described_class.call(type: "visual_review_screenshot", title: "Viewport", server_context: { run: run })

    expect(response).not_to be_error
    expect(described_class).to have_received(:call_browser_tool).with(run, "browser_screenshot", {}).ordered
  end

  it "rejects current-browser capture when another image source is also provided" do
    response = call(capture_current_browser: true)

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
    expect(response.content.first[:text]).to include("capture_current_browser: true")
    expect(response.content.first[:text]).to include("omit image_path and image_base64")
  end

  it "rejects an image exceeding the maximum size" do
    huge = Base64.strict_encode64("x" * (described_class::MAX_IMAGE_BYTES + 1))

    response = call(image_base64: huge)

    expect(response).to be_error
    expect(response.content.first[:text]).to include("exceeds maximum size")
    expect(run.workflow.reload.artifact("typed_artifacts")).to be_nil
  end

  it "stamps run_id/step_id/trigger_kind provenance even with no matching diff review version" do
    call

    entry = run.workflow.reload.artifact("typed_artifacts").first
    expect(entry).to include(
      "workflow_id"  => run.workflow_id,
      "run_id"       => run.id,
      "step_id"      => run.step_id,
      "trigger_kind" => run.workflow.trigger_kind
    )
    expect(entry.keys).not_to include("diff_review_version_id")
  end

  it "derives base_sha/head_sha/diff_review_version_id from the matching diff review version" do
    version = DiffReviewVersion.create!(
      job: run.job, workflow: run.workflow, run: run, version_index: 1,
      base_sha: "base123", head_sha: "head456",
      source_key: "workflow:#{run.workflow_id}:run:#{run.id}",
      files_snapshot: [], metadata: {}
    )

    call

    entry = run.workflow.reload.artifact("typed_artifacts").first
    expect(entry).to include(
      "base_sha" => "base123",
      "head_sha" => "head456",
      "diff_review_version_id" => version.id
    )
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
    expect(described_class.description).to include("prefer capture_current_browser: true")
    expect(described_class.input_schema_value.to_h.dig(:properties, :image_path, :description)).to include("Reserve this for files you know are workflow-local")
    expect(described_class.input_schema_value.to_h.dig(:properties, :capture_current_browser, :description)).to include("Prefer this for visual-review screenshots")
    expect(described_class.input_schema_value.to_h.dig(:properties, :subject, :description)).to include("browser_snapshot ref", "CSS selector")
    expect(described_class.input_schema_value.to_h.dig(:properties, :minimum_subject_visible_fraction, :description)).to include("Defaults to 0.5")
  end
end

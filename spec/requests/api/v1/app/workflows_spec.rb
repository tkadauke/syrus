require "rails_helper"

RSpec.describe "API: /api/v1/app/workflows/:workflow_id/coverage_hit_map", type: :request do
  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  def workflow_for(user)
    job = Factories.job(user: user)
    job.workflows.first
  end

  it "returns hit_map_attached: false when no blob is attached" do
    sign_in_as(user)
    workflow = workflow_for(user)

    get "/api/v1/app/workflows/#{workflow.id}/coverage_hit_map", params: { file: "app/models/user.rb" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["hit_map_attached"]).to be false
    expect(body["file"]).to eq("app/models/user.rb")
    expect(body["lines"]).to eq({})
  end

  it "returns the hit counts for the requested file when a blob is attached" do
    sign_in_as(user)
    workflow = workflow_for(user)
    hit_map = {
      "app/models/user.rb"    => { "1" => 3, "2" => 0, "5" => 1 },
      "app/models/post.rb"    => { "1" => 1 }
    }
    workflow.attach_coverage_hit_map!(hit_map)

    get "/api/v1/app/workflows/#{workflow.id}/coverage_hit_map", params: { file: "app/models/user.rb" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["hit_map_attached"]).to be true
    expect(body["file"]).to eq("app/models/user.rb")
    expect(body["lines"]).to eq("1" => 3, "2" => 0, "5" => 1)
  end

  it "returns empty lines for a file not present in the hit map" do
    sign_in_as(user)
    workflow = workflow_for(user)
    workflow.attach_coverage_hit_map!({ "app/models/user.rb" => { "1" => 1 } })

    get "/api/v1/app/workflows/#{workflow.id}/coverage_hit_map", params: { file: "app/models/missing.rb" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["hit_map_attached"]).to be true
    expect(body["lines"]).to eq({})
  end

  it "returns empty lines when the file param is omitted" do
    sign_in_as(user)
    workflow = workflow_for(user)
    workflow.attach_coverage_hit_map!({ "app/models/user.rb" => { "1" => 1 } })

    get "/api/v1/app/workflows/#{workflow.id}/coverage_hit_map"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["hit_map_attached"]).to be true
    expect(body["lines"]).to eq({})
  end

  it "returns 401 when signed out" do
    workflow = workflow_for(user)

    get "/api/v1/app/workflows/#{workflow.id}/coverage_hit_map"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 404 for a workflow belonging to another user" do
    sign_in_as(user)
    other_workflow = workflow_for(Factories.user)

    get "/api/v1/app/workflows/#{other_workflow.id}/coverage_hit_map"

    expect(response).to have_http_status(:not_found)
  end
end

RSpec.describe "API: /api/v1/app/workflows/:workflow_id/visual_artifact", type: :request do
  let(:user) { Factories.user }
  let(:png_bytes) { "\x89PNG\r\n\x1a\n".b }

  def workflow_for(user)
    job = Factories.job(user: user)
    job.workflows.first
  end

  it "returns the image bytes for an attached visual artifact" do
    sign_in_as(user)
    workflow = workflow_for(user)
    workflow.attach_visual_artifact!(type: "visual_review_screenshot", data: png_bytes, content_type: "image/png", filename: "screenshot.png")

    get "/api/v1/app/workflows/#{workflow.id}/visual_artifact", params: { type: "visual_review_screenshot" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(png_bytes)
    expect(response.headers["Content-Type"]).to eq("image/png")
  end

  it "returns 404 when no visual artifact is attached for the type" do
    sign_in_as(user)
    workflow = workflow_for(user)

    get "/api/v1/app/workflows/#{workflow.id}/visual_artifact", params: { type: "visual_review_screenshot" }

    expect(response).to have_http_status(:not_found)
  end

  it "returns 404 when the type param is missing" do
    sign_in_as(user)
    workflow = workflow_for(user)
    workflow.attach_visual_artifact!(type: "visual_review_screenshot", data: png_bytes, content_type: "image/png", filename: "screenshot.png")

    get "/api/v1/app/workflows/#{workflow.id}/visual_artifact"

    expect(response).to have_http_status(:not_found)
  end

  it "returns 401 when signed out" do
    workflow = workflow_for(user)

    get "/api/v1/app/workflows/#{workflow.id}/visual_artifact", params: { type: "visual_review_screenshot" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 404 for a workflow belonging to another user" do
    sign_in_as(user)
    other_workflow = workflow_for(Factories.user)
    other_workflow.attach_visual_artifact!(type: "visual_review_screenshot", data: png_bytes, content_type: "image/png", filename: "screenshot.png")

    get "/api/v1/app/workflows/#{other_workflow.id}/visual_artifact", params: { type: "visual_review_screenshot" }

    expect(response).to have_http_status(:not_found)
  end
end

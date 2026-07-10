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

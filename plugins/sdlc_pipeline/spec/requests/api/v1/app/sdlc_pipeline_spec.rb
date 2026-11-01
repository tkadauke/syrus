require "rails_helper"

RSpec.describe "API: repository SDLC pipeline", type: :request do
  it "authorizes through repository access and returns tabs plus bounded projection" do
    user = Factories.user
    repository = Factories.repository(user: user)
    Factories.job_record(repository: repository, user: user, state: "running", issue_title: "Build it")
    allow(RepoDeploymentStagesReader).to receive(:for_repository).and_return(double(stages: []))
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/sdlc_pipeline", params: { stage: "implementing", limit: 1 }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repository"]).to include("id" => repository.id, "slug" => repository.slug)
    expect(response.parsed_body["tabs"].map { |tab| tab["key"] }).to include("sdlc_pipeline.repository")
    expect(response.parsed_body.dig("drill_down", "items").length).to eq(1)
  end

  it "does not disclose an inaccessible repository" do
    repository = Factories.repository(user: Factories.user)
    sign_in_as(Factories.user)

    get "/api/v1/app/repositories/#{repository.id}/sdlc_pipeline"

    expect(response).to have_http_status(:not_found)
  end
end

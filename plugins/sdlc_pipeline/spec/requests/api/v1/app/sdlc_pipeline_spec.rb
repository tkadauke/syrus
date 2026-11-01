require "rails_helper"

RSpec.describe "API: repository SDLC pipeline", type: :request do
  describe "SmartFolder/FilterBar conformance" do
    let(:user) { Factories.user }
    let(:other_user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let!(:owned_job) { Factories.job_record(repository: repository, user: user, owner_user: user, state: "running") }
    let!(:other_job) { Factories.job_record(repository: repository, user: user, owner_user: other_user, state: "running") }
    let(:smart_folder_contract_subject) { SdlcPipeline::SmartFolders::SUBJECT }
    let(:smart_folder_contract_folder) do
      SmartFolder.ensure_builtins_for_subject!(smart_folder_contract_subject)
      SmartFolder.builtins(smart_folder_contract_subject).find_by!(name: "Mine")
    end
    let(:smart_folder_contract_seed_filter) { { "and" => [ { "field" => "owner_user_id", "op" => "is", "value" => "me" } ] } }
    let(:smart_folder_contract_seed_ids) { [ owned_job.id ] }
    let(:smart_folder_contract_replacement_filter) { { "and" => [ { "field" => "job_id", "op" => "is", "value" => other_job.id } ] } }
    let(:smart_folder_contract_replacement_ids) { [ other_job.id ] }
    let(:smart_folder_contract_unfiltered_ids) { [ owned_job.id, other_job.id ] }
    let(:smart_folder_contract_request) { ->(params) { get "/api/v1/app/repositories/#{repository.id}/sdlc_pipeline", params: params } }
    let(:smart_folder_contract_body) { response.parsed_body }
    let(:smart_folder_contract_result_ids) do
      smart_folder_contract_body.fetch("stages").flat_map { |stage| stage.fetch("highlighted_items") }.map { |row| row.fetch("id") }
    end

    before do
      allow(RepoDeploymentStagesReader).to receive(:for_repository).and_return(double(stages: []))
      sign_in_as(user)
    end

    include_examples "a SmartFolder-backed FilterBar endpoint", contract_surface: :repository
  end

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
    mine = response.parsed_body.fetch("smart_folders").find { |folder| folder.fetch("name") == "Mine" }
    expect(mine.fetch("path")).to eq("/repositories/#{repository.id}/plugin/sdlc-pipeline?smart_folder_id=#{mine.fetch('id')}")
    expect(response.parsed_body.fetch("filter_schema").map { |field| field.fetch("field") }).not_to include("state", "smart_folder_preset")
  end

  it "does not disclose an inaccessible repository" do
    repository = Factories.repository(user: Factories.user)
    sign_in_as(Factories.user)

    get "/api/v1/app/repositories/#{repository.id}/sdlc_pipeline"

    expect(response).to have_http_status(:not_found)
  end

  it "skips historical reconstruction for the live polling request" do
    user = Factories.user
    repository = Factories.repository(user: user)
    allow(RepoDeploymentStagesReader).to receive(:for_repository).and_return(double(stages: []))
    allow(SdlcPipeline::History).to receive(:new)
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/sdlc_pipeline", params: { history: "0" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).not_to have_key("history")
    expect(SdlcPipeline::History).not_to have_received(:new)
  end

  it "filters by the chat Jobs-tab association scope without including explicit attachments" do
    user = Factories.user
    repository = Factories.repository(user: user)
    chat = ChatSession.create!(user: user, title: "Release planning")
    proposed = Factories.job_record(repository: repository, user: user, state: "running")
    attached = Factories.job_record(repository: repository, user: user, state: "running")
    chat.proposals.create!(kind: "job", slug: "proposed", title: "Proposed", body: "Body", state: "confirmed", job: proposed)
    attached.chat_attachments.create!(chat_session: chat)
    allow(RepoDeploymentStagesReader).to receive(:for_repository).and_return(double(stages: []))
    sign_in_as(user)

    tree = { "and" => [ { "field" => "chat_session_id", "op" => "is", "value" => chat.id } ] }
    get "/api/v1/app/repositories/#{repository.id}/sdlc_pipeline", params: { q: Filters::QueryParam.encode(tree) }

    ids = response.parsed_body.fetch("stages").flat_map { |stage| stage.fetch("highlighted_items") }.map { |row| row.fetch("id") }
    expect(ids).to eq([ proposed.id ])
    expect(response.parsed_body.fetch("filter")).to eq(tree.deep_stringify_keys)
  end
end

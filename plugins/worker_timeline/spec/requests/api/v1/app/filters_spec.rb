require "rails_helper"

RSpec.describe "Worker Timeline filter suggestions", type: :request do
  def parse_body = JSON.parse(response.body)

  def enable_filter_metadata!
    PluginLifecycleJob.perform_now("worker_timeline", "on_enable")
  end

  after do
    WorkerTimeline::FilterRegistration.unregister!
  end

  it "rejects worker timeline suggestions while the plugin filter metadata is not registered" do
    user = Factories.user(admin: true)
    sign_in_as(user)

    get "/api/v1/app/filters/suggestions", params: { surface: "worker_timeline", subject: "worker_timeline", q: "syrus" }

    expect(response).to have_http_status(:bad_request)
  end

  it "rejects worker timeline usage while the plugin filter metadata is not registered" do
    user = Factories.user(admin: true)
    sign_in_as(user)

    post "/api/v1/app/filters/usage",
         params: {
           surface: "worker_timeline",
           subject: "worker_timeline",
           filter: {
             "and" => [
               { "field" => "repository_id", "op" => "is", "value" => "1" }
             ]
           }
         }

    expect(response).to have_http_status(:bad_request)
  end

  it "records worker timeline filter usage through plugin-registered metadata" do
    enable_filter_metadata!
    user = Factories.user(admin: true)
    repo = Factories.repository(user:, owner: "tkadauke", name: "syrus")
    sign_in_as(user)

    post "/api/v1/app/filters/usage",
         params: {
           surface: "worker_timeline",
           subject: "worker_timeline",
           filter: {
             "and" => [
               { "field" => "repository_id", "op" => "is", "value" => repo.id.to_s }
             ]
           }
         }

    expect(response).to have_http_status(:ok)
    expect(FilterUsage.find_by!(user:, surface: "worker_timeline", subject: "worker_timeline", label: "Repository is tkadauke/syrus").use_count).to eq(1)
  end

  it "suggests complete worker timeline filters from FK value matches" do
    enable_filter_metadata!
    user = Factories.user(admin: true)
    repo = Factories.repository(user:, owner: "tkadauke", name: "syrus")
    epic = Factories.epic(user:, repository: repo, title: "Syrus worker timeline rollout")
    SpawnedProcess.create!(
      kind: "agent",
      command: "codex exec",
      hostname: "syrus-worker-suggestions",
      started_at: 1.minute.ago
    )
    sign_in_as(user)

    get "/api/v1/app/filters/suggestions", params: { surface: "worker_timeline", subject: "worker_timeline", q: "syrus" }

    expect(response).to have_http_status(:ok)
    labels = parse_body.fetch("suggestions").map { |suggestion| suggestion.fetch("label") }
    expect(labels).to include(
      "Repository is tkadauke/syrus",
      "Epic is #{Filters::Schema.epic_label(epic)}",
      "Hostname is syrus-worker-suggestions"
    )
  end
end

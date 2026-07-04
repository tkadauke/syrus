require "rails_helper"

RSpec.describe "API: /api/v1/app/filters", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/filters/fk_options", params: { field: "job_id" }

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "returns normalized FK option payloads scoped to the current user" do
    user = Factories.user
    repo = Factories.repository(user: user)
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    own = Factories.job_record(user: user, repository: repo, issue_number: 42, issue_title: "Find me")
    Factories.job_record(user: other_user, repository: other_repo, issue_number: 43, issue_title: "Find me elsewhere")
    sign_in_as(user)

    get "/api/v1/app/filters/fk_options", params: { field: "job_id", q: "Find me" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq(
      "options" => [
        { "value" => own.id, "label" => "#42 Find me" }
      ]
    )
  end

  it "resolves explicit ids in bulk" do
    user = Factories.user
    repo = Factories.repository(user: user)
    old = Factories.job_record(user: user, repository: repo, issue_number: 7, issue_title: "Ancient task", created_at: 3.years.ago)
    recent = Factories.job_record(user: user, repository: repo, issue_number: 8, issue_title: "Recent task")
    sign_in_as(user)

    get "/api/v1/app/filters/fk_options", params: { field: "job_id", ids: [ old.id, recent.id ] }

    expect(response).to have_http_status(:ok)
    expect(parse_body["options"]).to contain_exactly(
      { "value" => old.id, "label" => "#7 Ancient task" },
      { "value" => recent.id, "label" => "#8 Recent task" }
    )
  end

  it "searches jobs by title but not by issue number or branch name" do
    user = Factories.user
    repo = Factories.repository(user:)
    by_title = Factories.job_record(user:, repository: repo, issue_number: 10, issue_title: "Add typeahead")
    by_number = Factories.job_record(user:, repository: repo, issue_number: 99, issue_title: "Unrelated")
    by_branch = Factories.job_record(user:, repository: repo, issue_number: 11, issue_title: "Branch match", branch_name: "syrus/fk-options")
    Factories.job_record(user:, repository: repo, issue_number: 100, issue_title: "99 bottles")
    sign_in_as(user)

    get "/api/v1/app/filters/fk_options", params: { field: "job_id", q: "typeahead" }
    expect(parse_body["options"].map { |row| row["value"] }).to eq([ by_title.id ])

    get "/api/v1/app/filters/fk_options", params: { field: "job_id", q: "99" }
    expect(parse_body["options"].map { |row| row["value"] }).not_to include(by_number.id)

    get "/api/v1/app/filters/fk_options", params: { field: "job_id", q: "fk-options" }
    expect(parse_body["options"].map { |row| row["value"] }).not_to include(by_branch.id)
  end

  it "searches jobs and epics by slug" do
    user = Factories.user
    repo = Factories.repository(user:)
    job = Factories.job_record(user:, repository: repo, issue_number: 10, issue_title: "Unrelated title")
    epic = Factories.epic(user:, repository: repo, title: "Unrelated epic")
    sign_in_as(user)

    get "/api/v1/app/filters/fk_options", params: { field: "job_id", q: "JOB-#{job.id}" }
    expect(parse_body["options"].map { |row| row["value"] }).to include(job.id)

    get "/api/v1/app/filters/fk_options", params: { field: "job_id", q: job.id.to_s }
    expect(parse_body["options"].map { |row| row["value"] }).to include(job.id)

    get "/api/v1/app/filters/fk_options", params: { field: "epic_id", q: "EPIC-#{epic.number}" }
    expect(parse_body["options"].map { |row| row["value"] }).to include(epic.id)

    get "/api/v1/app/filters/fk_options", params: { field: "epic_id", q: epic.number.to_s }
    expect(parse_body["options"].map { |row| row["value"] }).to include(epic.id)
  end

  it "caps search responses at 50 results" do
    user = Factories.user
    repo = Factories.repository(user:)
    60.times do |i|
      Factories.job_record(user:, repository: repo, issue_number: i + 1, issue_title: "Bulk searchable #{i}")
    end
    sign_in_as(user)

    get "/api/v1/app/filters/fk_options", params: { field: "job_id", q: "Bulk searchable" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["options"].size).to eq(50)
  end

  it "searches repositories, epics, tags, and hostnames through their label columns" do
    user = Factories.user
    repo = Factories.repository(user:, owner: "acme", name: "widgets")
    epic = Factories.epic(user:, repository: repo, title: "Typeahead migration")
    tag = Factories.tag(user:, name: "backend")
    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      hostname: "syrus-worker-alpha",
      started_at: 1.minute.ago
    )
    sign_in_as(user)

    get "/api/v1/app/filters/fk_options", params: { field: "repository_id", q: "widg" }
    expect(parse_body["options"]).to eq([{ "value" => repo.id, "label" => "acme/widgets" }])

    get "/api/v1/app/filters/fk_options", params: { field: "repository_id", q: "acme" }
    expect(parse_body["options"]).to eq([])

    get "/api/v1/app/filters/fk_options", params: { field: "epic_id", q: "migration" }
    expect(parse_body["options"]).to eq([{ "value" => epic.id, "label" => "#{epic.slug} Typeahead migration" }])

    get "/api/v1/app/filters/fk_options", params: { field: "tags", q: "back" }
    expect(parse_body["options"]).to eq([{ "value" => tag.id, "label" => "backend" }])

    get "/api/v1/app/filters/fk_options", params: { field: "hostname", q: "alpha" }
    expect(parse_body["options"]).to eq([{ "value" => "syrus-worker-alpha", "label" => "syrus-worker-alpha" }])
  end

  it "returns a structured error for unknown fields" do
    sign_in_as(Factories.user)

    get "/api/v1/app/filters/fk_options", params: { field: "user_id" }

    expect(response).to have_http_status(:bad_request)
    expect(parse_body.dig("error", "code")).to eq("unknown_field")
    expect(parse_body.dig("error", "message")).to eq("Unknown filter field.")
  end

  it "records filter usage through the explicit usage endpoint" do
    user = Factories.user
    repo = Factories.repository(user:, owner: "acme", name: "widgets")
    sign_in_as(user)
    state_tree = {
      "and" => [
        { "field" => "state", "op" => "is", "value" => "running" }
      ]
    }
    repository_tree = {
      "and" => [
        { "field" => "repository_id", "op" => "is", "value" => repo.id.to_s }
      ]
    }

    2.times do
      post "/api/v1/app/filters/usage", params: { surface: "dashboard", subject: "job", filter: state_tree }
      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("recorded" => true)
    end
    post "/api/v1/app/filters/usage", params: { surface: "dashboard", subject: "job", filter: repository_tree }

    expect(response).to have_http_status(:ok)
    expect(FilterUsage.find_by!(user:, surface: "dashboard", subject: "job", label: "State is Running").use_count).to eq(2)
    expect(FilterUsage.find_by!(user:, surface: "dashboard", subject: "job", label: "Repository is acme/widgets").use_count).to eq(1)
  end

  it "does not record incomplete value filters" do
    user = Factories.user
    sign_in_as(user)

    post "/api/v1/app/filters/usage",
         params: {
           surface: "dashboard",
           subject: "job",
           filter: {
             "and" => [
               { "field" => "repository_id", "op" => "is", "value" => "" },
               { "field" => "state", "op" => "is_none_of", "value" => [] },
               { "field" => "has_parent_job", "op" => "is_true", "value" => nil }
             ]
           }
         }

    expect(response).to have_http_status(:ok)
    expect(FilterUsage.pluck(:label)).to eq([ "Has parent is true" ])
  end

  it "does not fail the usage endpoint when recording hits a lock timeout" do
    user = Factories.user
    sign_in_as(user)
    allow(Filters::Suggestions).to receive(:record!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")

    post "/api/v1/app/filters/usage",
         params: {
           surface: "dashboard",
           subject: "job",
           filter: { "and" => [{ "field" => "state", "op" => "is", "value" => "running" }] }
         }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("recorded" => false)
  end

  it "suggests complete filters from FK value matches" do
    user = Factories.user
    repo = Factories.repository(user:, owner: "tkadauke", name: "syrus")
    other_repo = Factories.repository(user: Factories.user, owner: "tkadauke", name: "syrus-private")
    sign_in_as(user)

    get "/api/v1/app/filters/suggestions", params: { surface: "dashboard", subject: "job", q: "sy" }

    expect(response).to have_http_status(:ok)
    suggestions = parse_body.fetch("suggestions")
    expect(suggestions).to include(
      include(
        "label" => "Repository is tkadauke/syrus",
        "filter" => { "field" => "repository_id", "op" => "is", "value" => repo.id },
        "source" => "value"
      )
    )
    expect(suggestions.map { |suggestion| suggestion.dig("filter", "value") }).not_to include(other_repo.id)
  end

  it "ranks learned matching filters ahead of generated value suggestions" do
    user = Factories.user
    sign_in_as(user)
    filter = { "field" => "state", "op" => "is", "value" => "running" }
    FilterUsage.create!(
      user: user,
      surface: "dashboard",
      subject: "job",
      fingerprint: "state-running",
      label: "State is Running",
      filter_node: filter,
      use_count: 3,
      last_used_at: Time.current
    )

    get "/api/v1/app/filters/suggestions", params: { surface: "dashboard", subject: "job", q: "run" }

    expect(response).to have_http_status(:ok)
    suggestions = parse_body.fetch("suggestions")
    expect(suggestions.first).to include(
      "label" => "State is Running",
      "filter" => filter,
      "source" => "frequent"
    )
    expect(suggestions.count { |suggestion| suggestion.fetch("label") == "State is Running" }).to eq(1)
  end

  it "does not suggest filters that are already active" do
    user = Factories.user
    repo = Factories.repository(user:, owner: "tkadauke", name: "syrus")
    sign_in_as(user)
    active_tree = {
      "and" => [
        { "field" => "repository_id", "op" => "is", "value" => repo.id }
      ]
    }

    get "/api/v1/app/filters/suggestions",
        params: {
          surface: "dashboard",
          subject: "job",
          q: "sy",
          active_q: Filters::QueryParam.encode(active_tree)
        }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("suggestions").map { |suggestion| suggestion.fetch("label") }).not_to include("Repository is tkadauke/syrus")
  end
end

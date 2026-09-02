require "rails_helper"

RSpec.describe "API: /api/v1/app/tags", type: :request do
  let(:user) { Factories.user }
  let(:other) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  def capture_sql
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA"

      queries << payload[:sql].to_s.squish
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/tags"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "lists only the current user's tags with palette metadata" do
    sign_in_as(user)
    tag = Factories.tag(user: user, name: "mine", color: "blue")
    Factories.tag(user: other, name: "theirs", color: "red")
    repo = Factories.repository(user: user)
    job = Factories.job_record(repository: repo, issue_number: 7)
    job.tags << tag

    get "/api/v1/app/tags"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["tags"]).to contain_exactly(
      include("id" => tag.id, "name" => "mine", "color" => "blue", "jobs_count" => 1)
    )
    expect(body["palette"].first).to include("key" => "gray", "label" => "Gray", "bg" => "#f3f4f6")
    expect(response.body).not_to include("theirs")
  end

  it "does not load tagged jobs to compute tag counts" do
    sign_in_as(user)
    tag = Factories.tag(user: user, name: "mine", color: "blue")
    repo = Factories.repository(user: user)
    3.times do |issue_number|
      job = Factories.job_record(repository: repo, issue_number: issue_number + 1)
      job.tags << tag
    end

    queries = capture_sql { get "/api/v1/app/tags" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("tags").first).to include("jobs_count" => 3)
    expect(queries).not_to include(match(/SELECT\s+["`]?jobs["`]?\.\*/i))
  end

  it "creates a tag" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/tags", params: { tag: { name: "epic:attachments", color: "indigo" } }
    }.to change { user.tags.count }.by(1)

    expect(response).to have_http_status(:created)
    expect(user.tags.last.name).to eq("epic:attachments")
    expect(parse_body["message"]).to eq("Tag created.")
    expect(parse_body["tags"].first).to include("name" => "epic:attachments", "color" => "indigo")
  end

  it "returns validation errors" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/tags", params: { tag: { name: "", color: "nope" } }
    }.not_to change { user.tags.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("Name")
  end

  it "updates a tag" do
    sign_in_as(user)
    tag = Factories.tag(user: user, name: "old", color: "gray")

    patch "/api/v1/app/tags/#{tag.id}", params: { tag: { name: "new", color: "green" } }

    expect(response).to have_http_status(:ok)
    expect(tag.reload.name).to eq("new")
    expect(tag.color).to eq("green")
    expect(parse_body["message"]).to eq("Tag updated.")
  end

  it "deletes the tag and its job assignments" do
    sign_in_as(user)
    repo = Factories.repository(user: user)
    job = Factories.job_record(repository: repo, issue_number: 7)
    tag = Factories.tag(user: user, name: "doomed", color: "red")
    job.tags << tag

    expect {
      delete "/api/v1/app/tags/#{tag.id}"
    }.to change { JobTag.count }.by(-1)

    expect(response).to have_http_status(:ok)
    expect(Tag.exists?(tag.id)).to be(false)
    expect(parse_body["message"]).to eq("Tag deleted.")
  end

  it "does not allow managing another user's tags" do
    sign_in_as(user)
    tag = Factories.tag(user: other, name: "theirs", color: "red")

    patch "/api/v1/app/tags/#{tag.id}", params: { tag: { name: "stolen", color: "blue" } }

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("not_found")
    expect(tag.reload.name).to eq("theirs")
  end
end

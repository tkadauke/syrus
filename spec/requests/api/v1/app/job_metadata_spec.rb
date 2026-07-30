require "rails_helper"

RSpec.describe "App API job metadata commands", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(repository: repo, issue_number: 42, issue_title: "Repair the forum") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def app_job_path(path) = "/api/v1/app/jobs/#{job.id}#{path}"

  it "adds and removes tags for one of the current user's jobs" do
    expect(AppEvents).to receive(:broadcast).twice.with(
      user: user,
      type: "updated",
      resource: "job",
      id: job.id,
      changed: [ "tags" ]
    )

    expect {
      post app_job_path("/tags"), params: { tag_name: "theme:cleanup" }, as: :json
    }.to change { user.tags.count }.by(1)

    tag = user.tags.find_by!(name: "theme:cleanup")
    expect(response).to have_http_status(:ok)
    expect(job.reload.tags).to contain_exactly(tag)
    expect(parse_body).to include(
      "message" => "Tag added.",
      "tags" => [ include("id" => tag.id, "name" => "theme:cleanup", "color" => "gray") ]
    )

    delete app_job_path("/tags/#{tag.id}"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload.tags).to be_empty
    expect(parse_body).to include("message" => "Tag removed.", "tags" => [])
  end

  it "adds and removes manual dependencies" do
    target = Factories.job_record(repository: repo, issue_number: 41, issue_title: "Prepare marble")
    expect(AppEvents).to receive(:broadcast).twice.with(
      user: user,
      type: "updated",
      resource: "job",
      id: job.id,
      changed: [ "dependencies" ]
    )

    expect {
      post app_job_path("/dependencies"), params: { dependency_target: "job:#{target.id}" }, as: :json
    }.to change { job.dependencies.count }.by(1)

    dependency = job.reload.dependencies.sole
    expect(response).to have_http_status(:ok)
    expect(dependency).to be_manual
    expect(dependency.created_by_user).to eq(user)
    expect(parse_body).to include(
      "message" => "Dependency added.",
      "dependencies" => [ include("id" => dependency.id, "depends_on_job_id" => target.id, "manual" => true) ]
    )

    delete app_job_path("/dependencies/#{dependency.id}"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload.dependencies).to be_empty
    expect(parse_body).to include("message" => "Dependency removed.", "dependencies" => [])
  end

  it "does not allow removing parsed dependencies" do
    target = Factories.job_record(repository: repo, issue_number: 41)
    dependency = job.dependencies.create!(depends_on_job: target, source: "parsed")

    delete app_job_path("/dependencies/#{dependency.id}"), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("Parsed dependencies are kept for audit.")
    expect(job.reload.dependencies).to contain_exactly(dependency)
  end

  it "adds and removes manual epic dependencies" do
    epic = Factories.epic(user: user, repository: repo, title: "Platform migration")
    expect(AppEvents).to receive(:broadcast).twice.with(
      user: user,
      type: "updated",
      resource: "job",
      id: job.id,
      changed: [ "dependencies" ]
    )

    expect {
      post app_job_path("/epic_dependencies"), params: { depends_on_epic_id: epic.id }, as: :json
    }.to change { job.dependencies.count }.by(1)

    dependency = job.reload.dependencies.sole
    expect(response).to have_http_status(:ok)
    expect(dependency).to be_manual
    expect(dependency.depends_on_epic).to eq(epic)
    expect(dependency.created_by_user).to eq(user)
    expect(parse_body).to include(
      "message" => "Epic dependency added.",
      "dependencies" => [ include("depends_on_epic_id" => epic.id, "manual" => true) ]
    )

    delete app_job_path("/epic_dependencies/#{epic.id}"), as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload.dependencies).to be_empty
    expect(parse_body).to include("message" => "Epic dependency removed.", "dependencies" => [])
  end

  it "returns 404 when the epic is not found for the current user" do
    post app_job_path("/epic_dependencies"), params: { depends_on_epic_id: 99_999 }, as: :json

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "message")).to eq("Epic not found.")
  end

  it "returns 404 when the epic dependency to remove is not found" do
    epic = Factories.epic(user: user, repository: repo, title: "Nonexistent dep")

    delete app_job_path("/epic_dependencies/#{epic.id}"), as: :json

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "message")).to eq("Epic dependency not found.")
  end

  it "lets admins override dependency gates and start pending work" do
    prerequisite = Job.create!(user: user, repository: repo, issue_number: 41)
    target = Job.create!(user: user, repository: repo, issue_number: 42, issue_body: "Depends-on: #41")
    target.advance_after_triage!
    user.update!(admin: true)
    expect(target.runs).to be_empty
    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "job",
      id: target.id,
      changed: [ "dependencies" ]
    )

    expect {
      post "/api/v1/app/jobs/#{target.id}/dependencies/override", as: :json
    }.to have_enqueued_job(RunJob)

    expect(response).to have_http_status(:ok)
    expect(target.reload.dependencies_overridden_by_user).to eq(user)
    expect(target.runs.count).to eq(1)
    expect(parse_body.dig("job", "dependencies_overridden_by_user_id")).to eq(user.id)
    expect(prerequisite).to be_present
  end

  it "blocks dependency override for non-admin users" do
    user.update!(admin: false)

    post app_job_path("/dependencies/override"), as: :json

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "message")).to eq("Only admins can override dependencies.")
  end

  it "updates stack base" do
    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "job",
      id: job.id,
      changed: [ "stack_base" ]
    )

    patch app_job_path("/stack_base"), params: { stack_base: "main" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(job.reload.stack_base).to eq("main")
    expect(parse_body).to include("message" => "Stack base updated.")
    expect(parse_body.dig("job", "stack_base")).to eq("main")
  end

  it "marks invalid jobs valid and queues them" do
    invalid = Job.create!(user: user, repository: repo, issue_number: 50, issue_title: "Rebuild the aqueduct")
    invalid.update!(
      state: "closed",
      closure_reason: "duplicate",
      finished_at: Time.current,
      validity: "duplicate",
      invalidation_reason: "Already covered.",
      invalidation_evidence: [ "https://github.com/acme/widgets/issues/2" ]
    )
    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "job",
      id: invalid.id,
      changed: [ "validity", "state" ]
    )

    expect {
      post "/api/v1/app/jobs/#{invalid.id}/mark_valid", as: :json
    }.to change { invalid.reload.state }.from("closed").to("queued")
      .and change { invalid.runs.count }.from(0).to(1)

    expect(response).to have_http_status(:ok)
    expect(invalid.validity).to eq("valid")
    expect(invalid.invalidation_reason).to be_nil
    expect(invalid.invalidation_evidence).to eq([])
    expect(parse_body).to include("message" => "Job marked valid and re-queued.")
  end

  it "does not expose another user's job" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job_record(repository: other_repo, issue_number: 99)

    post "/api/v1/app/jobs/#{other_job.id}/tags", params: { tag_name: "theme:private" }, as: :json

    expect(response).to have_http_status(:not_found)
    expect(other_job.tags).to be_empty
  end
end

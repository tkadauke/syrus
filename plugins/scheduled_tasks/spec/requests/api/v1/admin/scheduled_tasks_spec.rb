require "rails_helper"

RSpec.describe "API: /api/v1/admin/scheduled_tasks", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:non_admin) { admin; Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { non_admin.generate_api_token! }

  let(:repository) { Factories.repository(user: admin, owner: "acme", name: "widgets") }

  let(:valid_cron_attrs) do
    {
      name: "Weekly tests",
      kind: "cron",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip",
      prompt: "Write missing tests."
    }
  end

  def auth(token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  describe "auth" do
    let(:task) { ScheduledTasks::Task.create!(repository: repository, user: admin, **valid_cron_attrs) }

    it "401s without an Authorization header" do
      get "/api/v1/admin/scheduled_tasks"
      expect(response).to have_http_status(:unauthorized)
      expect(parse_body.dig("error", "code")).to eq("unauthorized")
    end

    it "403s when the token belongs to a non-admin user" do
      get "/api/v1/admin/scheduled_tasks", headers: auth(non_admin_token)
      expect(response).to have_http_status(:forbidden)
      expect(parse_body.dig("error", "code")).to eq("forbidden")
    end

    it "answers plugin_disabled with the plugin disabled, even for an admin token" do
      PluginRecord.find_by!(name: "scheduled_tasks").update!(enabled: false)

      get "/api/v1/admin/scheduled_tasks", headers: auth(admin_token)
      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")

      get "/api/v1/admin/scheduled_tasks/#{task.id}", headers: auth(admin_token)
      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")

      post "/api/v1/admin/scheduled_tasks/#{task.id}/pause", headers: auth(admin_token)
      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
    end
  end

  describe "GET /scheduled_tasks" do
    it "lists tasks instance-wide, filterable by repository, user, kind, and paused" do
      other_repo = Factories.repository(user: admin, owner: "acme", name: "gadgets")
      other_user = Factories.user

      cron = ScheduledTasks::Task.create!(repository: repository, user: admin, **valid_cron_attrs)
      one_shot = ScheduledTasks::Task.create!(repository: repository, user: admin,
        name: "One-off", kind: "one_shot", fire_at: 1.day.from_now, pr_pileup_policy: "skip", prompt: "Do it once.")
      paused = ScheduledTasks::Task.create!(repository: other_repo, user: admin, **valid_cron_attrs.merge(name: "Paused task"))
      paused.pause!(reason: "operator")
      ScheduledTasks::Task.create!(repository: repository, user: other_user, **valid_cron_attrs.merge(name: "Someone else's"))

      get "/api/v1/admin/scheduled_tasks", headers: auth(admin_token)
      expect(response).to have_http_status(:ok)
      expect(parse_body["scheduled_tasks"].map { |t| t["id"] }).to contain_exactly(cron.id, one_shot.id, paused.id,
        ScheduledTasks::Task.find_by!(name: "Someone else's").id)

      get "/api/v1/admin/scheduled_tasks", params: { repository: "acme/widgets" }, headers: auth(admin_token)
      expect(parse_body["scheduled_tasks"].map { |t| t["id"] }).to contain_exactly(cron.id, one_shot.id,
        ScheduledTasks::Task.find_by!(name: "Someone else's").id)

      get "/api/v1/admin/scheduled_tasks", params: { user: other_user.email_address }, headers: auth(admin_token)
      expect(parse_body["scheduled_tasks"].map { |t| t["id"] }).to contain_exactly(ScheduledTasks::Task.find_by!(name: "Someone else's").id)

      get "/api/v1/admin/scheduled_tasks", params: { kind: "one_shot" }, headers: auth(admin_token)
      expect(parse_body["scheduled_tasks"].map { |t| t["id"] }).to contain_exactly(one_shot.id)

      get "/api/v1/admin/scheduled_tasks", params: { paused: "true" }, headers: auth(admin_token)
      expect(parse_body["scheduled_tasks"].map { |t| t["id"] }).to contain_exactly(paused.id)

      get "/api/v1/admin/scheduled_tasks", params: { paused: "false" }, headers: auth(admin_token)
      expect(parse_body["scheduled_tasks"].map { |t| t["id"] }).to contain_exactly(cron.id, one_shot.id,
        ScheduledTasks::Task.find_by!(name: "Someone else's").id)
    end

    it "excludes archived tasks by default" do
      archived = ScheduledTasks::Task.create!(repository: repository, user: admin, **valid_cron_attrs)
      archived.soft_delete!

      get "/api/v1/admin/scheduled_tasks", headers: auth(admin_token)

      expect(parse_body["scheduled_tasks"]).to be_empty
    end

    it "filters by due_before against the computed next fire time" do
      soon = ScheduledTasks::Task.create!(repository: repository, user: admin,
        name: "Soon", kind: "one_shot", fire_at: 1.hour.from_now, pr_pileup_policy: "skip", prompt: "x")
      later = ScheduledTasks::Task.create!(repository: repository, user: admin,
        name: "Later", kind: "one_shot", fire_at: 10.days.from_now, pr_pileup_policy: "skip", prompt: "x")

      get "/api/v1/admin/scheduled_tasks", params: { due_before: 1.day.from_now.iso8601 }, headers: auth(admin_token)

      ids = parse_body["scheduled_tasks"].map { |t| t["id"] }
      expect(ids).to include(soon.id)
      expect(ids).not_to include(later.id)
    end
  end

  describe "GET /scheduled_tasks/:id" do
    it "returns detail including cron expression, pileup policy, failure count, and fire times" do
      task = ScheduledTasks::Task.create!(repository: repository, user: admin, **valid_cron_attrs)
      task.update_columns(consecutive_failure_count: 2, last_fired_at: 3.hours.ago)

      get "/api/v1/admin/scheduled_tasks/#{task.id}", headers: auth(admin_token)

      expect(response).to have_http_status(:ok)
      expect(parse_body).to include(
        "id" => task.id,
        "cron_expression" => task.hourly_cron_expression,
        "pr_pileup_policy" => "skip",
        "consecutive_failure_count" => 2
      )
      expect(parse_body["last_fired_at"]).to be_present
      expect(parse_body).to have_key("next_fire_at")
      expect(parse_body["prompt"]).to eq("Write missing tests.")
    end
  end

  describe "POST /scheduled_tasks/:id/pause and /unpause" do
    it "pauses and unpauses a task without a session cookie" do
      task = ScheduledTasks::Task.create!(repository: repository, user: admin, **valid_cron_attrs)

      post "/api/v1/admin/scheduled_tasks/#{task.id}/pause", headers: auth(admin_token)
      expect(response).to have_http_status(:ok)
      expect(task.reload.state).to eq("paused")
      expect(parse_body["paused"]).to eq(true)
      expect(parse_body["pause_reason"]).to eq("operator")

      task.update_columns(consecutive_failure_count: 5)
      post "/api/v1/admin/scheduled_tasks/#{task.id}/unpause", headers: auth(admin_token)
      expect(response).to have_http_status(:ok)
      expect(task.reload.state).to eq("scheduled")
      expect(task.consecutive_failure_count).to eq(0)
      expect(parse_body["paused"]).to eq(false)
    end
  end

  describe "POST /scheduled_tasks/:id/fire" do
    it "fires the same kind=cron Job the poller would, through the shared service" do
      task = ScheduledTasks::Task.create!(repository: repository, user: admin, **valid_cron_attrs)
      job = Factories.job_record(user: admin, repository: repository, scheduled_task_id: task.id, kind: "cron", issue_number: nil)
      result = ScheduledTasks::Fire::Result.new(job: job, skipped: false, reason: nil)
      service = instance_double(ScheduledTasks::Fire, call: result)
      allow(ScheduledTasks::Fire).to receive(:new).with(task).and_return(service)

      post "/api/v1/admin/scheduled_tasks/#{task.id}/fire", headers: auth(admin_token)

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to eq("Fired (#{job.slug}).")
      expect(parse_body["fire_result"]).to include("fired" => true, "job_id" => job.id)
    end

    it "rejects firing an archived task" do
      task = ScheduledTasks::Task.create!(repository: repository, user: admin, **valid_cron_attrs)
      task.soft_delete!

      post "/api/v1/admin/scheduled_tasks/#{task.id}/fire", headers: auth(admin_token)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("not_fireable")
    end
  end
end

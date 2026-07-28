require "rails_helper"

RSpec.describe App::DashboardPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def call(params = {})
    described_class.call(user: user, params: ActionController::Parameters.new(params))
  end

  describe "default inbox view" do
    # Builtins are seeded by the service on each call, but we need them available
    # for assertions before the second call, so ensure them explicitly.
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    let(:inbox_folder) { SmartFolder.find_builtin_by_attention("inbox") }

    it "reports the inbox SmartFolder's ID as active_smart_folder_id" do
      result = call(subject: "job", view: "list")
      expect(result[:active_smart_folder_id]).to eq(inbox_folder.id)
    end

    it "reads sort preferences from the inbox folder's slot (round-trip)" do
      # The frontend saves sort preferences keyed by active_smart_folder_id.
      # On the default inbox view that is inbox_folder.id, so we write there.
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: inbox_folder.id,
        sort_column: "started_at",
        sort_direction: "asc"
      )

      result = call(subject: "job", view: "list")

      # active_folder_key_for_prefs must resolve to inbox_folder.id so the
      # preference slot written above is actually read back here.
      expect(result[:preferences][:sort]).to include(column: "started_at", direction: "asc")
    end

    it "does not bleed inbox folder preferences into the key-null slot" do
      # Preferences saved under the inbox folder's numeric ID must not affect
      # reads keyed by "null" (explicit smart_folder_id=nil in the URL).
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: inbox_folder.id,
        sort_column: "started_at",
        sort_direction: "asc"
      )

      # An explicit smart_folder_id=nil in params means "no folder" — should
      # NOT see the inbox-keyed preference.
      result = call(subject: "job", view: "list", smart_folder_id: nil)

      default_column = User::DASHBOARD_SORT_DEFAULTS.fetch("job").fetch("column")
      expect(result[:preferences][:sort]).to include(column: default_column)
    end

    it "does not activate inbox default when a filter param is present" do
      result = call(subject: "job", view: "list", "q" => "state:running")
      # With a filter param, default_inbox_smart_folder? is false;
      # active_smart_folder should be nil (no inbox fallback).
      expect(result[:active_smart_folder_id]).to be_nil
    end
  end

  describe "priority sort" do
    let(:urgent_job) { Factories.job_record(user: user, repository: repo, priority: "urgent") }
    let(:high_job) { Factories.job_record(user: user, repository: repo, priority: "high") }
    let(:medium_job) { Factories.job_record(user: user, repository: repo, priority: "medium") }
    let(:low_job) { Factories.job_record(user: user, repository: repo, priority: "low") }

    before { [ urgent_job, high_job, medium_job, low_job ] }

    it "sorts ascending: urgent first, then high, medium, low" do
      result = call(subject: "job", sort_column: "priority", sort_direction: "asc")
      ids = result[:items].map { |j| j[:id] }
      expect(ids.index(urgent_job.id)).to be < ids.index(high_job.id)
      expect(ids.index(high_job.id)).to be < ids.index(medium_job.id)
      expect(ids.index(medium_job.id)).to be < ids.index(low_job.id)
    end

    it "sorts descending: low first, then medium, high, urgent" do
      result = call(subject: "job", sort_column: "priority", sort_direction: "desc")
      ids = result[:items].map { |j| j[:id] }
      expect(ids.index(low_job.id)).to be < ids.index(medium_job.id)
      expect(ids.index(medium_job.id)).to be < ids.index(high_job.id)
      expect(ids.index(high_job.id)).to be < ids.index(urgent_job.id)
    end

    it "exposes priority as a sortable column in controls" do
      result = call(subject: "job")
      expect(result[:controls][:sort_columns]).to include("priority")
    end

    it "exposes priority as an optional column" do
      result = call(subject: "job")
      optional_keys = result[:controls][:columns][:optional].map { |c| c[:key] }
      expect(optional_keys).to include("priority")
    end
  end

  describe "landing queue blocker job entries" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    let(:landing_queue_folder) { SmartFolder.find_builtin_by_attention("landing_queue") }
    let(:blocker_repo) { Factories.repository(user: user) }

    it "includes repository, latest workflow fields, and timestamps for blocker jobs in landing queue entries" do
      blocker_job = Factories.job_record(user: user, repository: blocker_repo, state: "implemented", issue_number: 20, issue_title: "Blocker")
      workflow = Workflow.create!(job: blocker_job, trigger_kind: "initial", state: "failed")

      approved_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      approved_job.approve!(via: "github_review")

      JobDependency.create!(job: approved_job, depends_on_job: blocker_job, source: "manual", created_by_user: user)
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)
      entries = result.dig(:landing_queue, :entries)
      blocker_entry = entries&.flat_map { |e| e[:blocker_jobs] }&.find { |b| b[:id] == blocker_job.id }

      expect(blocker_entry).to include(
        id: blocker_job.id,
        repository: hash_including(id: blocker_repo.id, slug: blocker_repo.slug),
        latest_workflow_id: workflow.id,
        latest_workflow_state: "failed",
        latest_workflow_trigger_kind: "initial",
        created_at: blocker_job.created_at.iso8601
      )
    end
  end
end

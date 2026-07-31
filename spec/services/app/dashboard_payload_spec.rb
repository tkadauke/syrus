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

  describe "commits_behind_base column" do
    let(:far_behind_job) { Factories.job_record(user: user, repository: repo).tap { |j| j.update_columns(commits_behind_base: 55) } }
    let(:slightly_behind_job) { Factories.job_record(user: user, repository: repo).tap { |j| j.update_columns(commits_behind_base: 5) } }
    let(:current_job) { Factories.job_record(user: user, repository: repo).tap { |j| j.update_columns(commits_behind_base: 0) } }
    let(:unknown_job) { Factories.job_record(user: user, repository: repo) }

    before { [ far_behind_job, slightly_behind_job, current_job, unknown_job ] }

    it "serializes commits_behind_base in each job item" do
      result = call(subject: "job")
      item = result[:items].find { |j| j[:id] == far_behind_job.id }
      expect(item[:commits_behind_base]).to eq(55)
    end

    it "serializes nil for jobs with no commits_behind_base" do
      result = call(subject: "job")
      item = result[:items].find { |j| j[:id] == unknown_job.id }
      expect(item[:commits_behind_base]).to be_nil
    end

    it "exposes commits_behind_base as an optional column" do
      result = call(subject: "job")
      optional_keys = result[:controls][:columns][:optional].map { |c| c[:key] }
      expect(optional_keys).to include("commits_behind_base")
    end

    it "exposes commits_behind_base as a sortable column in controls" do
      result = call(subject: "job")
      expect(result[:controls][:sort_columns]).to include("commits_behind_base")
    end

    it "sorts ascending: lowest commits_behind_base first, nulls last" do
      result = call(subject: "job", sort_column: "commits_behind_base", sort_direction: "asc")
      ids = result[:items].map { |j| j[:id] }
      expect(ids.index(current_job.id)).to be < ids.index(slightly_behind_job.id)
      expect(ids.index(slightly_behind_job.id)).to be < ids.index(far_behind_job.id)
      expect(ids.index(far_behind_job.id)).to be < ids.index(unknown_job.id)
    end

    it "sorts descending: highest commits_behind_base first, nulls last" do
      result = call(subject: "job", sort_column: "commits_behind_base", sort_direction: "desc")
      ids = result[:items].map { |j| j[:id] }
      expect(ids.index(far_behind_job.id)).to be < ids.index(slightly_behind_job.id)
      expect(ids.index(slightly_behind_job.id)).to be < ids.index(current_job.id)
      expect(ids.index(current_job.id)).to be < ids.index(unknown_job.id)
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

  describe "commits_behind_base in job items" do
    it "includes commits_behind_base in the job item payload" do
      job = Factories.job_record(user: user, repository: repo)
      job.update_columns(commits_behind_base: 25)

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(commits_behind_base: 25)
    end

    it "includes nil commits_behind_base when not yet computed" do
      job = Factories.job_record(user: user, repository: repo)

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(commits_behind_base: nil)
    end
  end

  describe "blocked folder blocked_reason" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    let(:blocked_folder) { SmartFolder.find_builtin_by_attention("blocked") }

    it "returns nil blocked_reason outside the blocked folder" do
      job = Factories.job_record(user: user, repository: repo)
      job.update_columns(pr_mergeable: false)

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item[:blocked_reason]).to be_nil
    end

    it "shows required columns including blocked_reason when viewing blocked folder" do
      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      required_keys = result[:controls][:columns][:required].map { |c| c[:key] }

      expect(required_keys).to include("blocked_reason")
      expect(required_keys).not_to include("landing_queue_position")
    end

    it "reports pr_not_mergeable for jobs with pr_mergeable false" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      job.update_columns(pr_mergeable: false)

      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item[:blocked_reason]).to eq("pr_not_mergeable")
    end

    it "prefers landing_queue_blocked_reason over pr_not_mergeable" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      job.update_columns(pr_mergeable: false, landing_queue_blocked_reason: "PR checks failing on JOB-99")

      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item[:blocked_reason]).to eq("PR checks failing on JOB-99")
    end

    it "shows waiting-for-job reason for dependency-blocked jobs" do
      blocker = Factories.job_record(user: user, repository: repo, state: "running")
      blocked_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      JobDependency.create!(job: blocked_job, depends_on_job: blocker, source: "manual", created_by_user: user)

      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      item = result[:items].find { |i| i[:id] == blocked_job.id }

      expect(item[:blocked_reason]).to eq("waiting for JOB-#{blocker.id} to merge")
    end

    it "does not show dep reason when the only dependency is already satisfied" do
      blocker = Factories.job_record(user: user, repository: repo, state: "closed", closure_reason: "pr_merged")
      # Job is in the blocked folder due to pr_mergeable:false, not the dep (which is satisfied)
      blocked_job = Factories.job_record(user: user, repository: repo, state: "running")
      blocked_job.update_columns(pr_mergeable: false)
      JobDependency.create!(job: blocked_job, depends_on_job: blocker, source: "manual", created_by_user: user)

      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      item = result[:items].find { |i| i[:id] == blocked_job.id }

      # satisfied dep should not be shown; pr_not_mergeable takes effect instead
      expect(item[:blocked_reason]).to eq("pr_not_mergeable")
    end
  end

  describe "start_blocked_reason on job items" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    it "includes start_blocked_reason from the queued workflow's artifacts" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "stack_dependencies_not_ready" }
      )

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(start_blocked_reason: "stack_dependencies_not_ready")
    end

    it "includes nil start_blocked_reason when no blocked workflow exists" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(job: job, trigger_kind: "initial", state: "queued")

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(start_blocked_reason: nil)
    end
  end

  describe "blocked_count on queued smart folder" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    it "includes blocked_count on the queued folder when blocked jobs exist" do
      queued_job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: queued_job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "urgent_job_active" }
      )

      result = call(subject: "job")
      queued_folder = result[:smart_folders].find { |f| f[:key] == "queued" }

      expect(queued_folder[:blocked_count]).to eq(1)
    end

    it "includes blocked_count of zero when no blocked queued jobs exist" do
      Factories.job_record(user: user, repository: repo, state: "queued")

      result = call(subject: "job")
      queued_folder = result[:smart_folders].find { |f| f[:key] == "queued" }

      expect(queued_folder[:blocked_count]).to eq(0)
    end

    it "does not include blocked_count on non-queued folders" do
      result = call(subject: "job")
      inbox_folder = result[:smart_folders].find { |f| f[:key] == "inbox" }

      expect(inbox_folder).not_to have_key(:blocked_count)
    end
  end

  describe "start_blocked filter" do
    it "filters job items to queued workflows with a start blocked reason" do
      blocked_job = Factories.job_record(user: user, repository: repo, state: "queued")
      unblocked_job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: blocked_job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "main_branch_broken" }
      )
      Workflow.create!(job: unblocked_job, trigger_kind: "initial", state: "queued")

      result = call(subject: "job", start_blocked: "1")

      expect(result[:items].map { |item| item[:id] }).to contain_exactly(blocked_job.id)
    end
  end
end

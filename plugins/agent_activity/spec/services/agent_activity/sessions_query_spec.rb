require "rails_helper"

RSpec.describe AgentActivity::SessionsQuery do
  let!(:operator) { Factories.user(admin: false) }
  let(:my_repository) { Factories.repository(user: operator) }
  let(:other_repository) { Factories.repository(user: Factories.user) }

  def sessions_for(scope:, user:, page: 1, per: AgentActivity::SessionsQuery::DEFAULT_PER)
    filter = AgentActivity::Filter.new(nil, user: user)
    described_class.call(scope: scope, user: user, filter: filter, page: page, per: per)
  end

  def capture_sql
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] unless payload[:name].to_s.match?(/\ASCHEMA|TRANSACTION\z/)
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def agent_activity_job_with_run(**attrs)
    job = Factories.job_with_run(**attrs)
    record_agent_process(job.runs.last)
    job
  end

  def record_agent_process(run)
    agent = Agent.find_or_create_for!(run)
    SpawnedProcess.create!(
      agent: agent,
      run: run,
      workflow: run.workflow,
      kind: "agent",
      command: "codex exec",
      hostname: "spec-host",
      started_at: run.started_at || run.created_at,
      finished_at: run.state == "running" ? nil : (run.finished_at || run.updated_at),
      outcome: run.state == "running" ? nil : run.state
    )
  end

  def record_chat_process(chat, started_at:, finished_at:, outcome:)
    agent = Agent.find_or_create_for!(chat)
    SpawnedProcess.create!(
      agent: agent,
      chat_session: chat,
      kind: "agent",
      command: "codex exec",
      hostname: "spec-host",
      started_at: started_at,
      finished_at: finished_at,
      outcome: outcome
    )
    agent
  end

  def design_doc_agent_run(requested_by_user:, title: "Design notes")
    doc = DesignDocs::DesignDoc.create!(
      owner_user: requested_by_user,
      title: title,
      markdown: "Alpha beta gamma",
      visibility: "private"
    )
    version = doc.versions.create!(markdown: doc.markdown, version_number: 1, actor_kind: "user", actor_user: requested_by_user)
    doc.update!(current_version: version)
    comment_result = DesignDocs::CreateComment.call(
      design_doc: doc,
      user: requested_by_user,
      attributes: { body: "Please help", start_offset: 0, end_offset: 5, selected_markdown: "Alpha" }
    )
    DesignDocs::DesignDocAgentRun.create!(
      design_doc: doc,
      thread: comment_result.thread,
      triggering_comment: comment_result.comment,
      requested_by_user: requested_by_user,
      base_version: version,
      agent_provider: "codex",
      status: "succeeded",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago
    )
  end

  def row_job_ids(result)
    result[:rows].map { |agent| agent.resumable.job_id }
  end

  it "only includes Runs whose Step is agentic" do
    job = agent_activity_job_with_run(repository: my_repository, user: operator, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 1.minute.ago })
    agent_activity_job_with_run(repository: my_repository, user: operator, step_attrs: { kind: "prepare" }, run_attrs: { state: "running", started_at: 1.minute.ago })

    result = sessions_for(scope: :mine, user: operator)

    expect(row_job_ids(result)).to eq([ job.id ])
  end

  describe "scope: :mine" do
    it "includes sessions on repositories the user belongs to" do
      job = agent_activity_job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(row_job_ids(result)).to contain_exactly(job.id)
    end

    it "excludes sessions on repositories the user does not belong to and does not own" do
      agent_activity_job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows]).to be_empty
    end

    it "includes a Job the user effectively owns even on a repository they don't otherwise belong to" do
      job = agent_activity_job_with_run(repository: other_repository, user: operator, owner_user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(row_job_ids(result)).to contain_exactly(job.id)
    end

    it "includes sessions on a repository granted through Team membership, mirroring Job.accessible_to" do
      team_member = Factories.user
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: team_member, role: "member")
      team.team_repositories.create!(repository: other_repository, role: "read")
      job = agent_activity_job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: team_member)

      expect(row_job_ids(result)).to contain_exactly(job.id)
    end

    it "includes sessions on an upstream repository of a repository the user belongs to, mirroring Job.accessible_to" do
      upstream_repository = Factories.repository(user: Factories.user)
      Factories.repository(user: operator, upstream_repository: upstream_repository)
      job = agent_activity_job_with_run(repository: upstream_repository, user: upstream_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(row_job_ids(result)).to contain_exactly(job.id)
    end

    it "matches exactly the Job set predicted by Job.accessible_to/effectively_owned_by" do
      team_member = Factories.user
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: team_member, role: "member")
      team.team_repositories.create!(repository: other_repository, role: "read")

      upstream_repository = Factories.repository(user: Factories.user)
      Factories.repository(user: team_member, upstream_repository: upstream_repository)

      owned_elsewhere = Factories.repository(user: Factories.user)

      visible_via_team = agent_activity_job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 3.minutes.ago })
      visible_via_upstream = agent_activity_job_with_run(repository: upstream_repository, user: upstream_repository.user, run_attrs: { state: "running", started_at: 2.minutes.ago })
      visible_via_ownership = agent_activity_job_with_run(repository: owned_elsewhere, user: team_member, owner_user: team_member, run_attrs: { state: "running", started_at: 1.minute.ago })
      not_visible = agent_activity_job_with_run(repository: owned_elsewhere, user: owned_elsewhere.user, run_attrs: { state: "running", started_at: 30.seconds.ago })

      predicted_job_ids = Job.accessible_to(team_member).or(Job.effectively_owned_by(team_member)).pluck(:id)

      result = sessions_for(scope: :mine, user: team_member)

      expect(predicted_job_ids).to include(visible_via_team.id, visible_via_upstream.id, visible_via_ownership.id)
      expect(predicted_job_ids).not_to include(not_visible.id)
      expect(row_job_ids(result)).to match_array(predicted_job_ids & [ visible_via_team.id, visible_via_upstream.id, visible_via_ownership.id, not_visible.id ])
    end
  end

  describe "scope: :admin" do
    it "includes sessions across every repository" do
      job = agent_activity_job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :admin, user: Factories.user(admin: true))

      expect(row_job_ids(result)).to include(job.id)
    end

    it "still self-scopes chat-backed sessions to the requesting admin" do
      admin = Factories.user(admin: true)
      admin_chat = ChatSession.create!(user: admin, repository: Factories.repository(user: admin), mode: "coding")
      other_chat = ChatSession.create!(user: operator, repository: my_repository, mode: "coding")
      admin_agent = record_chat_process(admin_chat, started_at: 2.minutes.ago, finished_at: nil, outcome: nil)
      record_chat_process(other_chat, started_at: 1.minute.ago, finished_at: nil, outcome: nil)

      result = sessions_for(scope: :admin, user: admin)

      expect(result[:rows]).to contain_exactly(admin_agent)
    end
  end

  describe "chat-backed agents" do
    it "collapses multiple turns into one Agent Activity row" do
      chat = ChatSession.create!(user: operator, repository: my_repository, mode: "coding")
      agent = record_chat_process(chat, started_at: 3.minutes.ago, finished_at: 2.minutes.ago, outcome: "succeeded")
      record_chat_process(chat, started_at: 1.minute.ago, finished_at: nil, outcome: nil)

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows]).to contain_exactly(agent)
      expect(result[:running_count]).to eq(1)
    end

    it "treats Failed as the latest spawned process outcome only" do
      latest_success_chat = ChatSession.create!(user: operator, repository: my_repository, mode: "coding")
      latest_failed_chat = ChatSession.create!(user: operator, repository: my_repository, mode: "coding")
      record_chat_process(latest_success_chat, started_at: 4.minutes.ago, finished_at: 3.minutes.ago, outcome: "failed")
      record_chat_process(latest_success_chat, started_at: 2.minutes.ago, finished_at: 1.minute.ago, outcome: "succeeded")
      failed_agent = record_chat_process(latest_failed_chat, started_at: 1.minute.ago, finished_at: Time.current, outcome: "failed")
      filter = AgentActivity::Filter.from_tree({ "and" => [ { "field" => "status", "op" => "is", "value" => "failed" } ] }, user: operator)

      result = described_class.call(scope: :mine, user: operator, filter: filter)

      expect(result[:rows]).to contain_exactly(failed_agent)
    end
  end

  describe "design-doc-backed agents" do
    it "includes visible design-doc agent runs with design-doc context" do
      run = design_doc_agent_run(requested_by_user: operator, title: "Merge train design")
      agent = Agent.find_or_create_for!(run)
      SpawnedProcess.create!(
        agent: agent,
        kind: "agent",
        command: "codex exec",
        hostname: "spec-host",
        started_at: 1.minute.ago,
        finished_at: 30.seconds.ago,
        outcome: "succeeded"
      )

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows]).to contain_exactly(agent)
      payload = AgentActivity::SessionSerializer.call(agent)
      expect(payload[:role_label]).to eq("Design Doc")
      expect(payload[:outcome_summary]).to include("DOC-#{run.design_doc_id}", "Merge train design")
    end
  end

  describe "running_count" do
    it "counts running sessions within scope regardless of pagination/filter" do
      agent_activity_job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })
      agent_activity_job_with_run(repository: my_repository, user: operator, run_attrs: { state: "succeeded", started_at: 10.minutes.ago, finished_at: 5.minutes.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:running_count]).to eq(1)
      expect(result[:total]).to eq(2)
    end
  end

  describe "pagination" do
    it "defaults to 20 rows per page" do
      21.times { |n| agent_activity_job_with_run(repository: my_repository, user: operator, issue_number: n + 1, run_attrs: { state: "running", started_at: (n + 1).minutes.ago }) }

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows].size).to eq(20)
      expect(result[:total]).to eq(21)
      expect(result[:per]).to eq(20)
    end

    it "limits and pages rows while total reflects the full filtered count" do
      3.times { |n| agent_activity_job_with_run(repository: my_repository, user: operator, issue_number: n + 1, run_attrs: { state: "running", started_at: (n + 1).minutes.ago }) }

      result = sessions_for(scope: :mine, user: operator, page: 1, per: 2)

      expect(result[:rows].size).to eq(2)
      expect(result[:total]).to eq(3)
      expect(result[:page]).to eq(1)
      expect(result[:per]).to eq(2)
    end

    it "uses a page-probe total for unfiltered feeds instead of counting every matching run" do
      22.times { |n| agent_activity_job_with_run(repository: my_repository, user: operator, issue_number: n + 1, run_attrs: { state: "running", started_at: (n + 1).minutes.ago }) }

      queries = capture_sql do
        result = sessions_for(scope: :mine, user: operator)

        expect(result[:rows].size).to eq(20)
        expect(result[:total]).to eq(21)
      end

      expect(queries.grep(/COUNT/i)).to be_empty
    end
  end

  describe "ordering" do
    it "orders most-recently-started first" do
      older = agent_activity_job_with_run(repository: my_repository, user: operator, run_attrs: { state: "succeeded", started_at: 20.minutes.ago, finished_at: 15.minutes.ago })
      newer = agent_activity_job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(row_job_ids(result)).to eq([ newer.id, older.id ])
    end
  end

  describe "visibility query shape" do
    # Regression guard for the query-shape half of this fix: visibility must
    # be resolved as a single `job_id IN (SELECT ...)` filter sourced from
    # Job.accessible_to/effectively_owned_by, not an ad-hoc `.or` spanning the
    # already-joined Run/Step/Job relation. The old shape forced the OR (and
    # its per-branch subqueries) to be evaluated against the joined relation
    # directly instead of once over `jobs` alone, which is what actually made
    # the query hard to plan.
    it "filters through one job_id subquery instead of an OR across the joined relation" do
      relation = described_class.visible_relation(scope: :mine, user: operator)

      sql = relation.to_sql
      outer_clause = sql.split("(SELECT", 2).first

      expect(sql).to match(/"?agents"?\."?resumable_type"?\s*=\s*'Run'/i)
      expect(sql).to match(/"?runs"?\."?job_id"?\s+IN\s+\(SELECT/i)
      expect(outer_clause).not_to match(/repository_id/i)
      expect(outer_clause).not_to match(/\bOR\b/i)
    end
  end
end

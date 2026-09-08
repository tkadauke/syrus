require "rails_helper"

RSpec.describe AgentActivity::SessionsQuery do
  let!(:operator) { Factories.user(admin: false) }
  let(:my_repository) { Factories.repository(user: operator) }
  let(:other_repository) { Factories.repository(user: Factories.user) }

  def sessions_for(scope:, user:, page: 1, per: AgentActivity::SessionsQuery::DEFAULT_PER)
    filter = AgentActivity::Filter.new(nil, user: user)
    described_class.call(scope: scope, user: user, filter: filter, page: page, per: per)
  end

  it "only includes Runs whose Step is agentic" do
    job = Factories.job_with_run(repository: my_repository, user: operator, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 1.minute.ago })
    Factories.job_with_run(repository: my_repository, user: operator, step_attrs: { kind: "prepare" }, run_attrs: { state: "running", started_at: 1.minute.ago })

    result = sessions_for(scope: :mine, user: operator)

    expect(result[:rows].map(&:job_id)).to eq([ job.id ])
  end

  describe "scope: :mine" do
    it "includes sessions on repositories the user belongs to" do
      job = Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows].map(&:job_id)).to contain_exactly(job.id)
    end

    it "excludes sessions on repositories the user does not belong to and does not own" do
      Factories.job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows]).to be_empty
    end

    it "includes a Job the user effectively owns even on a repository they don't otherwise belong to" do
      job = Factories.job_with_run(repository: other_repository, user: operator, owner_user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows].map(&:job_id)).to contain_exactly(job.id)
    end

    it "includes sessions on a repository granted through Team membership, mirroring Job.accessible_to" do
      team_member = Factories.user
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: team_member, role: "member")
      team.team_repositories.create!(repository: other_repository, role: "read")
      job = Factories.job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: team_member)

      expect(result[:rows].map(&:job_id)).to contain_exactly(job.id)
    end

    it "includes sessions on an upstream repository of a repository the user belongs to, mirroring Job.accessible_to" do
      upstream_repository = Factories.repository(user: Factories.user)
      Factories.repository(user: operator, upstream_repository: upstream_repository)
      job = Factories.job_with_run(repository: upstream_repository, user: upstream_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows].map(&:job_id)).to contain_exactly(job.id)
    end

    it "matches exactly the Job set predicted by Job.accessible_to/effectively_owned_by" do
      team_member = Factories.user
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: team_member, role: "member")
      team.team_repositories.create!(repository: other_repository, role: "read")

      upstream_repository = Factories.repository(user: Factories.user)
      Factories.repository(user: team_member, upstream_repository: upstream_repository)

      owned_elsewhere = Factories.repository(user: Factories.user)

      visible_via_team = Factories.job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 3.minutes.ago })
      visible_via_upstream = Factories.job_with_run(repository: upstream_repository, user: upstream_repository.user, run_attrs: { state: "running", started_at: 2.minutes.ago })
      visible_via_ownership = Factories.job_with_run(repository: owned_elsewhere, user: team_member, owner_user: team_member, run_attrs: { state: "running", started_at: 1.minute.ago })
      not_visible = Factories.job_with_run(repository: owned_elsewhere, user: owned_elsewhere.user, run_attrs: { state: "running", started_at: 30.seconds.ago })

      predicted_job_ids = Job.accessible_to(team_member).or(Job.effectively_owned_by(team_member)).pluck(:id)

      result = sessions_for(scope: :mine, user: team_member)

      expect(predicted_job_ids).to include(visible_via_team.id, visible_via_upstream.id, visible_via_ownership.id)
      expect(predicted_job_ids).not_to include(not_visible.id)
      expect(result[:rows].map(&:job_id)).to match_array(predicted_job_ids & [ visible_via_team.id, visible_via_upstream.id, visible_via_ownership.id, not_visible.id ])
    end
  end

  describe "scope: :admin" do
    it "includes sessions across every repository" do
      job = Factories.job_with_run(repository: other_repository, user: other_repository.user, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :admin, user: Factories.user(admin: true))

      expect(result[:rows].map(&:job_id)).to include(job.id)
    end
  end

  describe "running_count" do
    it "counts running sessions within scope regardless of pagination/filter" do
      Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })
      Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "succeeded", started_at: 10.minutes.ago, finished_at: 5.minutes.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:running_count]).to eq(1)
      expect(result[:total]).to eq(2)
    end
  end

  describe "pagination" do
    it "defaults to 20 rows per page" do
      21.times { |n| Factories.job_with_run(repository: my_repository, user: operator, issue_number: n + 1, run_attrs: { state: "running", started_at: (n + 1).minutes.ago }) }

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows].size).to eq(20)
      expect(result[:total]).to eq(21)
      expect(result[:per]).to eq(20)
    end

    it "limits and pages rows while total reflects the full filtered count" do
      3.times { |n| Factories.job_with_run(repository: my_repository, user: operator, issue_number: n + 1, run_attrs: { state: "running", started_at: (n + 1).minutes.ago }) }

      result = sessions_for(scope: :mine, user: operator, page: 1, per: 2)

      expect(result[:rows].size).to eq(2)
      expect(result[:total]).to eq(3)
      expect(result[:page]).to eq(1)
      expect(result[:per]).to eq(2)
    end
  end

  describe "ordering" do
    it "orders most-recently-started first" do
      older = Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "succeeded", started_at: 20.minutes.ago, finished_at: 15.minutes.ago })
      newer = Factories.job_with_run(repository: my_repository, user: operator, run_attrs: { state: "running", started_at: 1.minute.ago })

      result = sessions_for(scope: :mine, user: operator)

      expect(result[:rows].map(&:job_id)).to eq([ newer.id, older.id ])
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
      query = described_class.new(scope: :mine, user: operator, filter: AgentActivity::Filter.new(nil, user: operator))
      relation = query.send(:visibility_scoped, query.send(:base_relation))

      sql = relation.to_sql
      outer_clause = sql.split("(SELECT", 2).first

      expect(sql).to match(/"?runs"?\."?job_id"?\s+IN\s+\(SELECT/i)
      expect(outer_clause).not_to match(/repository_id/i)
      expect(outer_clause).not_to match(/\bOR\b/i)
    end
  end
end

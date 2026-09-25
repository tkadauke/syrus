require "rails_helper"

RSpec.describe "App API repository tests", type: :request do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  def encoded_filter(chips)
    tree = { "and" => chips }
    Base64.urlsafe_encode64(JSON.generate(tree), padding: false)
  end

  def make_test_run
    @test_run ||= begin
      run = Factories.job(user: user, repository: repo).initial_run
      TestInsights::TestRun.create!(
        run: run,
        repository: repo,
        grader_name: "rspec",
        total_count: 1,
        passed_count: 0,
        failed_count: 1,
        skipped_count: 0,
        error_count: 0
      )
    end
  end

  def make_identity(name:, suite_name: "Suite", file_path: nil)
    TestInsights::TestIdentity.create!(
      repository: repo,
      fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: suite_name, name: name),
      suite_name: suite_name,
      name: name,
      file_path: file_path
    )
  end

  def make_case(identity:, status:, created_at: Time.current, duration_ms: 125)
    test_case = TestInsights::TestCase.create!(
      test_run: make_test_run,
      repository: repo,
      test_identity: identity,
      suite_name: identity.suite_name,
      name: identity.name,
      file_path: identity.file_path,
      status: status,
      duration_ms: duration_ms,
      failure_message: status == "failed" ? "expected true" : nil,
      created_at: created_at,
      updated_at: created_at
    )
    identity.refresh_summary!
    test_case
  end

  describe "GET /api/v1/app/repositories/:repository_id/tests" do
    it "returns interesting failing, flaky, and slow tests by default" do
      failing = make_identity(name: "fails recently")
      flaky = make_identity(name: "flakes recently")
      slow = make_identity(name: "runs slowly")
      passing = make_identity(name: "passes quickly")
      make_case(identity: failing, status: "failed", created_at: 3.minutes.ago)
      make_case(identity: flaky, status: "failed", created_at: 2.minutes.ago)
      make_case(identity: flaky, status: "passed", created_at: 1.minute.ago)
      make_case(identity: slow, status: "passed", duration_ms: 4_500)
      make_case(identity: passing, status: "passed", duration_ms: 50)

      get "/api/v1/app/repositories/#{repo.id}/tests"

      expect(response).to have_http_status(:ok)
      tests_by_name = parse_body.fetch("tests").index_by { |test| test.fetch("name") }
      expect(tests_by_name.keys).to contain_exactly("flakes recently", "fails recently", "runs slowly")
      expect(tests_by_name.fetch("flakes recently").fetch("interesting_reasons")).to include("failing", "flaky")
      expect(tests_by_name.fetch("runs slowly").fetch("interesting_reasons")).to include("slow")
    end

    it "searches durable tests by name via the query filter chip" do
      make_case(identity: make_identity(name: "needle browser test"), status: "passed")
      make_case(identity: make_identity(name: "unrelated test"), status: "passed")

      q = encoded_filter([ { "field" => "query", "op" => "contains", "value" => "needle" } ])
      get "/api/v1/app/repositories/#{repo.id}/tests", params: { q: q }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("tests").map { |test| test.fetch("name") }).to eq([ "needle browser test" ])
      expect(parse_body.fetch("filter")).to eq("and" => [ { "field" => "query", "op" => "contains", "value" => "needle" } ])
    end

    it "filters durable tests by reason via the reason filter chip" do
      failing = make_identity(name: "fails recently")
      make_identity(name: "passes quickly")
      make_case(identity: failing, status: "failed", created_at: 3.minutes.ago)

      q = encoded_filter([ { "field" => "reason", "op" => "is", "value" => "failing" } ])
      get "/api/v1/app/repositories/#{repo.id}/tests", params: { q: q }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("tests").map { |test| test.fetch("name") }).to eq([ "fails recently" ])
    end

    it "combines the query and reason filter chips" do
      failing = make_identity(name: "needle fails recently")
      make_case(identity: failing, status: "failed", created_at: 3.minutes.ago)
      make_case(identity: make_identity(name: "needle passes quickly"), status: "passed")

      q = encoded_filter([
        { "field" => "query", "op" => "contains", "value" => "needle" },
        { "field" => "reason", "op" => "is", "value" => "failing" }
      ])
      get "/api/v1/app/repositories/#{repo.id}/tests", params: { q: q }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("tests").map { |test| test.fetch("name") }).to eq([ "needle fails recently" ])
    end

    it "filters durable tests by status, suite, and file path chips" do
      matching = make_identity(name: "matches metadata", suite_name: "Models::JobSpec", file_path: "spec/models/job_spec.rb")
      wrong_status = make_identity(name: "wrong status", suite_name: "Models::JobSpec", file_path: "spec/models/job_spec.rb")
      wrong_suite = make_identity(name: "wrong suite", suite_name: "Requests::JobSpec", file_path: "spec/models/job_spec.rb")
      wrong_file = make_identity(name: "wrong file", suite_name: "Models::JobSpec", file_path: "spec/services/job_service_spec.rb")

      make_case(identity: matching, status: "passed")
      make_case(identity: wrong_status, status: "failed")
      make_case(identity: wrong_suite, status: "passed")
      make_case(identity: wrong_file, status: "passed")

      q = encoded_filter([
        { "field" => "status", "op" => "is", "value" => "passed" },
        { "field" => "suite_name", "op" => "contains", "value" => "Models" },
        { "field" => "file_path", "op" => "contains", "value" => "models/job" }
      ])
      get "/api/v1/app/repositories/#{repo.id}/tests", params: { q: q }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("tests").map { |test| test.fetch("name") }).to eq([ "matches metadata" ])
    end

    it "exposes the filter schema for the FilterBar so search and metadata chips can go" do
      get "/api/v1/app/repositories/#{repo.id}/tests"

      expect(response).to have_http_status(:ok)
      fields = parse_body.fetch("filter_schema").map { |field| field.fetch("field") }
      expect(fields).to contain_exactly("query", "reason", "status", "suite_name", "file_path")
    end

    it "uses persisted recent stats without reading raw test cases" do
      identities = [
        make_identity(name: "slow browser test"),
        make_identity(name: "flaky browser test")
      ]
      make_case(identity: identities.first, status: "passed", duration_ms: 2_000)
      make_case(identity: identities.second, status: "failed", created_at: 2.minutes.ago)
      make_case(identity: identities.second, status: "passed", created_at: 1.minute.ago)

      test_case_selects = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
        sql = payload[:sql].to_s
        test_case_selects << sql if sql.match?(/FROM "?test_insight_cases"?/i)
      end
      expect_any_instance_of(TestInsights::TestIdentity).not_to receive(:recent_stats)

      begin
        get "/api/v1/app/repositories/#{repo.id}/tests"
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("tests").map { |test| test.fetch("name") }).to contain_exactly("slow browser test", "flaky browser test")
      expect(test_case_selects).to be_empty
    end

    it "enqueues missing identity backfills instead of doing them inline" do
      TestInsights::TestCase.create!(
        test_run: make_test_run,
        repository: repo,
        suite_name: "BackfillSpec",
        name: "creates identity later",
        status: "passed",
        duration_ms: 25
      )

      test_case_selects = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
        sql = payload[:sql].to_s
        test_case_selects << sql if sql.match?(/FROM "?test_insight_cases"?/i)
      end

      begin
        expect {
          get "/api/v1/app/repositories/#{repo.id}/tests"
        }.to have_enqueued_job(BackfillTestIdentitiesJob).with(repo.id).on_queue("indexing")
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("tests")).to eq([])
      expect(test_case_selects).to be_empty
    end
  end

  describe "GET /api/v1/app/repositories/:repository_id/tests/:id" do
    it "returns history newest first with run links, duration points, and pagination metadata" do
      identity = make_identity(name: "tracks history", suite_name: "HistorySpec")
      failed = make_case(identity: identity, status: "failed", duration_ms: 250, created_at: 2.minutes.ago)
      passed = make_case(identity: identity, status: "passed", duration_ms: 100, created_at: 1.minute.ago)

      get "/api/v1/app/repositories/#{repo.id}/tests/#{identity.id}"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("test", "name")).to eq("tracks history")
      expect(body.fetch("history").map { |row| row.fetch("id") }).to eq([ passed.id, failed.id ])
      expect(body.fetch("history").last.dig("run", "path")).to include("#run-")
      expect(body.fetch("duration_points").map { |row| row.fetch("duration_ms") }).to eq([ 250, 100 ])
      expect(body.fetch("pagination")).to eq(
        "page" => 1, "per_page" => Api::V1::App::RepositoryTestsController::PER_PAGE, "total" => 2, "total_pages" => 1
      )
    end

    it "paginates history across pages" do
      identity = make_identity(name: "paginated history", suite_name: "HistorySpec")
      cases = (1..25).map { |i| make_case(identity: identity, status: "passed", created_at: i.minutes.ago) }

      get "/api/v1/app/repositories/#{repo.id}/tests/#{identity.id}", params: { page: 1, per_page: 10 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.fetch("history").map { |row| row.fetch("id") }).to eq(cases.first(10).map(&:id))
      expect(body.fetch("pagination")).to eq("page" => 1, "per_page" => 10, "total" => 25, "total_pages" => 3)

      get "/api/v1/app/repositories/#{repo.id}/tests/#{identity.id}", params: { page: 3, per_page: 10 }

      body = parse_body
      expect(body.fetch("history").map { |row| row.fetch("id") }).to eq(cases[20..24].map(&:id))
      expect(body.fetch("pagination")).to eq("page" => 3, "per_page" => 10, "total" => 25, "total_pages" => 3)
    end
  end

  describe "repository access" do
    it "allows a RepositoryMembership collaborator to view the tests tab" do
      collaborator = Factories.user(email_address: "collaborator@example.com")
      repo.repository_memberships.create!(user: collaborator, role: "read")
      sign_in_as(collaborator)

      get "/api/v1/app/repositories/#{repo.id}/tests"

      expect(response).to have_http_status(:ok)
    end

    it "404s for a user who is neither the owner nor a member" do
      unrelated_user = Factories.user(email_address: "unrelated@example.com")
      sign_in_as(unrelated_user)

      get "/api/v1/app/repositories/#{repo.id}/tests"

      expect(response).to have_http_status(:not_found)
    end
  end
end

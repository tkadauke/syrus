require "rails_helper"

RSpec.describe "Test Insight MCP tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def create_identity!(name:, suite_name: "Suite", repo: repository, attrs: {})
    TestIdentity.create!({
      repository: repo,
      fingerprint: TestIdentity.fingerprint_for(suite_name: suite_name, name: name),
      suite_name: suite_name,
      name: name
    }.merge(attrs))
  end

  def create_case!(identity:, status:, created_at:, duration_ms: 100, grader_name: "rspec", failure_message: nil, failure_backtrace: nil, output: nil)
    run = Factories.job(user: identity.repository.user, repository: identity.repository).initial_run
    test_run = TestRun.create!(
      run: run,
      repository: identity.repository,
      grader_name: grader_name,
      total_count: 1,
      passed_count: status == "passed" ? 1 : 0,
      failed_count: status == "failed" ? 1 : 0,
      skipped_count: status == "skipped" ? 1 : 0,
      error_count: status == "error" ? 1 : 0,
      duration_ms: duration_ms
    )

    TestCase.create!(
      test_run: test_run,
      repository: identity.repository,
      test_identity: identity,
      suite_name: identity.suite_name,
      name: identity.name,
      status: status,
      duration_ms: duration_ms,
      failure_message: failure_message,
      failure_backtrace: failure_backtrace,
      output: output,
      created_at: created_at,
      updated_at: created_at
    ).tap { identity.refresh_summary! }
  end

  def payload_from(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  describe Mcp::Tools::ListRepositoryTestInsightsTool do
    it "lists visible repository test identities with recent stats and latest refs" do
      fast = create_identity!(name: "fast", attrs: { file_path: "spec/fast_spec.rb" })
      slow = create_identity!(name: "slow", attrs: { file_path: "spec/slow_spec.rb" })
      create_case!(identity: fast, status: "passed", created_at: 3.minutes.ago, duration_ms: 100)
      create_case!(identity: slow, status: "failed", created_at: 2.minutes.ago, duration_ms: 2_500, failure_message: "boom")

      response = described_class.call(
        server_context: { chat_session: chat_session },
        repository: "acme/widgets",
        filter: "recently_seen",
        sort: "last_duration",
        direction: "desc",
        lookback: 5
      )

      expect(response).not_to be_error
      payload = payload_from(response)
      tests = payload.fetch(:tests)
      expect(payload.dig(:repository, :slug)).to eq("acme/widgets")
      expect(payload).to include(filter: "recently_seen", sort: "last_duration", direction: "desc", lookback: 5)
      expect(tests.map { |test| test.fetch(:id) }).to eq([ slow.id, fast.id ])
      expect(tests.first).to include(
        suite_name: "Suite",
        name: "slow",
        file_path: "spec/slow_spec.rb",
        last_status: "failed",
        last_duration_ms: 2_500,
        failed_count: 1,
        passed_count: 0,
        failure_rate: 1.0,
        avg_duration_ms: 2_500,
        interesting_reasons: include("failing", "slow")
      )
      expect(tests.first.dig(:latest, :run, :slug)).to match(/\ARUN-\d+\z/)
      expect(tests.first.dig(:latest, :job, :slug)).to match(/\AJOB-\d+\z/)
    end

    it "filters identities by grader name" do
      rspec_identity = create_identity!(name: "rspec example")
      jest_identity = create_identity!(name: "jest example")
      create_case!(identity: rspec_identity, status: "passed", created_at: 2.minutes.ago, grader_name: "rspec")
      create_case!(identity: jest_identity, status: "passed", created_at: 1.minute.ago, grader_name: "jest")

      response = described_class.call(
        server_context: { chat_session: chat_session },
        repository_id: repository.id,
        grader_name: "jest"
      )

      expect(response).not_to be_error
      expect(payload_from(response).fetch(:tests).map { |test| test.fetch(:name) }).to eq([ "jest example" ])
    end

    it "rejects repositories outside the caller's visibility" do
      foreign = Factories.repository(owner: "other", name: "private")

      response = described_class.call(
        server_context: { chat_session: chat_session },
        repository_id: foreign.id
      )

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not_authorized")
    end

    it "defaults workflow calls to the current run repository" do
      run = Factories.job(user: user, repository: repository).initial_run
      identity = create_identity!(name: "current repo")
      create_case!(identity: identity, status: "passed", created_at: 1.minute.ago)

      response = described_class.call(server_context: { run_id: run.id })

      expect(response).not_to be_error
      expect(payload_from(response).fetch(:tests).map { |test| test.fetch(:id) }).to include(identity.id)
    end
  end

  describe Mcp::Tools::ReadTestInsightTool do
    it "reads recent history, duration points, references, and bounded failure snippets" do
      identity = create_identity!(name: "fails sometimes")
      old_case = create_case!(identity: identity, status: "passed", created_at: 3.minutes.ago, duration_ms: 80)
      failed_case = create_case!(
        identity: identity,
        status: "failed",
        created_at: 1.minute.ago,
        duration_ms: 120,
        failure_message: "Expected true to be false",
        failure_backtrace: "spec/example_spec.rb:12\n" * 300,
        output: "log line\n" * 500
      )

      response = described_class.call(
        server_context: { chat_session: chat_session },
        test_identity_id: identity.id,
        history_limit: 10
      )

      expect(response).not_to be_error
      payload = payload_from(response)
      expect(payload.dig(:repository, :id)).to eq(repository.id)
      expect(payload.dig(:test, :id)).to eq(identity.id)
      expect(payload.fetch(:history).map { |entry| entry.dig(:test_case, :id) }).to eq([ failed_case.id, old_case.id ])
      expect(payload.fetch(:duration_points).map { |point| point.fetch(:test_case_id) }).to eq([ old_case.id, failed_case.id ])
      expect(payload.dig(:related, :grader_names)).to eq([ "rspec" ])
      expect(payload.dig(:history, 0, :failure, :message, :text)).to eq("Expected true to be false")
      expect(payload.dig(:history, 0, :failure, :backtrace, :truncated)).to be(true)
      expect(payload.dig(:history, 0, :job, :slug)).to match(/\AJOB-\d+\z/)
    end

    it "can omit failure snippets" do
      identity = create_identity!(name: "quiet failure")
      create_case!(identity: identity, status: "failed", created_at: 1.minute.ago, failure_message: "secret")

      response = described_class.call(
        server_context: { chat_session: chat_session },
        test_identity_id: identity.id,
        include_failures: false
      )

      expect(response).not_to be_error
      expect(payload_from(response).dig(:history, 0)).not_to have_key(:failure)
    end

    it "rejects test identities outside the caller's visibility" do
      foreign_identity = create_identity!(name: "foreign", repo: Factories.repository)

      response = described_class.call(
        server_context: { chat_session: chat_session },
        test_identity_id: foreign_identity.id
      )

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not_authorized")
    end
  end
end

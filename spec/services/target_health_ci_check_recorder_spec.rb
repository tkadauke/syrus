require "rails_helper"

RSpec.describe TargetHealthCiCheckRecorder do
  around do |example|
    Dir.mktmpdir("target-health-ci-spec") do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:head_sha) { "abc1234567890000000000000000000000000000" }

  it "records mapped successful CI checks as target health" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
          sources: ["app/**/*.rb"]
          ci_checks: ["Backend CI"]
    YAML
    write("app/model.rb", "class Model\nend\n")

    records = record_checks([
      { name: "Backend CI", status: "completed", conclusion: "success", html_url: "https://github.test/run/1" }
    ])

    expect(records.size).to eq(1)
    record = records.first
    expect(record).to have_attributes(
      repository: repository,
      target_label: "//:backend",
      project_id: "repo",
      commit_sha: head_sha,
      status: "passed"
    )
    expect(record.metadata).to include(
      "health_source" => "ci_check",
      "check_name" => "Backend CI",
      "check_conclusion" => "success",
      "target_kind" => "repo_check"
    )
    expect(record.artifacts).to include("html_url" => "https://github.test/run/1")
  end

  it "does not record unmapped CI success as target health" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
          ci_checks: ["Backend CI"]
    YAML

    expect {
      record_checks([
        { name: "Unrelated CI", status: "completed", conclusion: "success" }
      ])
    }.not_to change(TargetHealthRecord, :count)
  end

  it "maps failed and stale conclusions without dispatch context" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
          ci_checks: ["Backend CI"]
        - name: frontend
          kind: repo_check
          run: npm test
          ci_checks: ["Frontend CI"]
    YAML

    records = record_checks([
      { name: "Backend CI", status: "completed", conclusion: "failure" },
      { name: "Frontend CI", status: "completed", conclusion: "stale" }
    ])

    expect(records.map { |record| [ record.target_label, record.status ] }).to contain_exactly(
      [ "//:backend", "failed" ],
      [ "//:frontend", "stale" ]
    )
  end

  it "updates retried check results for the same target fingerprint" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
          ci_checks: ["Backend CI"]
    YAML
    write("app/model.rb", "class Model\nend\n")

    failed = record_checks([
      { name: "Backend CI", status: "completed", conclusion: "failure", summary: "first attempt" }
    ]).first
    passed = record_checks([
      { name: "Backend CI", status: "completed", conclusion: "success", summary: "retry passed" }
    ]).first

    expect(passed.id).to eq(failed.id)
    expect(TargetHealthRecord.count).to eq(1)
    expect(passed.reload).to have_attributes(status: "passed")
    expect(passed.artifacts).to include("summary" => "retry passed")
  end

  it "records the worst result once when several checks map to one target, regardless of order" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
          ci_checks: ["Ruby 3.3", "Ruby 3.4"]
    YAML

    [
      [
        { name: "Ruby 3.3", status: "completed", conclusion: "failure" },
        { name: "Ruby 3.4", status: "completed", conclusion: "success" }
      ],
      [
        { name: "Ruby 3.4", status: "completed", conclusion: "success" },
        { name: "Ruby 3.3", status: "completed", conclusion: "failure" }
      ]
    ].each do |checks|
      records = record_checks(checks)

      expect(records.one?).to be(true)
      expect(records.first).to have_attributes(status: "failed", target_label: "//:backend")
      expect(records.first.metadata).to include(
        "check_names" => contain_exactly("Ruby 3.3", "Ruby 3.4"),
        "check_name" => "Ruby 3.3"
      )
    end

    expect(TargetHealthRecord.count).to eq(1)
  end

  it "records a target as inconclusive while one of its mapped checks is pending" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
          ci_checks: ["Ruby 3.3", "Ruby 3.4"]
    YAML

    records = record_checks(
      [ { name: "Ruby 3.3", status: "completed", conclusion: "success" } ],
      pending_checks: [ { name: "Ruby 3.4", status: "in_progress" } ]
    )

    expect(records.one?).to be(true)
    expect(records.first).to have_attributes(status: "inconclusive", target_label: "//:backend")
    expect(records.first.metadata).to include(
      "check_statuses" => { "Ruby 3.3" => "completed", "Ruby 3.4" => "in_progress" }
    )
  end

  it "invalidates an existing pass when a mapped sibling check later becomes pending" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
          ci_checks: ["Ruby 3.3", "Ruby 3.4"]
    YAML

    passed = record_checks([
      { name: "Ruby 3.3", status: "completed", conclusion: "success" }
    ]).first

    pending = record_checks(
      [ { name: "Ruby 3.3", status: "completed", conclusion: "success" } ],
      pending_checks: [ { name: "Ruby 3.4", status: "in_progress" } ]
    ).first

    expect(pending.id).to eq(passed.id)
    expect(pending.reload).to have_attributes(status: "inconclusive")
    expect(TargetHealthRecord.passed).to be_empty
  end

  it "falls back to exact executable target names when no explicit check mapping exists" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
    YAML

    records = record_checks([
      { name: "backend", status: "completed", conclusion: "success" }
    ])

    expect(records.first.target_label).to eq("//:backend")
  end

  def record_checks(checks, pending_checks: [])
    described_class.record!(
      job: job,
      head_sha: head_sha,
      detail: { completed_checks: checks, pending_checks: pending_checks },
      graph: TargetGraph::Compiler.compile(@dir),
      workspace_path: @dir.to_s
    )
  end

  def write(path, content)
    full_path = @dir.join(path)
    FileUtils.mkdir_p(full_path.dirname)
    full_path.write(content)
  end
end

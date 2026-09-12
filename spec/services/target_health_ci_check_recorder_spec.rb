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

  def record_checks(checks)
    described_class.record!(
      job: job,
      head_sha: head_sha,
      detail: { completed_checks: checks },
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

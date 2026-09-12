require "rails_helper"

RSpec.describe CiRepair::TargetContext do
  around do |example|
    Dir.mktmpdir("ci-repair-target-context-spec") do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:head_sha) { "abc1234567890000000000000000000000000000" }

  it "adds target identity, source scope, project, dependencies, and repair suggestions to mapped failed checks" do
    write(".syrus.yml", <<~YAML)
      project:
        id: repo
        label: Web App
      targets:
        - name: shared
          kind: library
          sources: ["lib/**/*.rb"]
        - name: backend
          kind: repo_check
          run: bin/check-backend
          sources: ["app/**/*.rb"]
          deps: [":shared"]
          ci_checks: ["Backend CI"]
    YAML

    result = call([{ name: "Backend CI", status: "completed", conclusion: "failure" }])
    context = result.failed_checks.first.fetch("target_context")

    expect(context).to include(
      "target_label" => "//:backend",
      "target_kind" => "repo_check",
      "project_id" => "repo",
      "project_label" => "Web App",
      "source_scope" => [ "app/**/*.rb" ],
      "dependencies" => [ "//:shared" ]
    )
    expect(context["dependency_context"]).to include(
      include("target_label" => "//:shared", "source_scope" => [ "lib/**/*.rb" ])
    )
    expect(context["suggested_fixes"].join("\n")).to include("add an explicit `deps:` edge")
  end

  it "leaves unmapped failed checks unchanged" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
          ci_checks: ["Backend CI"]
    YAML

    result = call([{ name: "Unrelated CI", status: "completed", conclusion: "failure" }])

    expect(result.failed_checks.first).not_to have_key("target_context")
    expect(result.missed_edges).to be_empty
  end

  it "reports a missed edge when a mapped failed check targets a prior skipped selection" do
    prior = Workflow.create!(
      job: job,
      trigger_kind: "landing_validation",
      state: "succeeded",
      artifacts: {
        Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY => [
          {
            "name" => "backend",
            "target_label" => "//:backend",
            "affected" => false,
            "reason" => "no matching files changed",
            "target_fingerprints" => { "input_fingerprint" => "fp" }
          }
        ]
      }
    )
    write(".syrus.yml", <<~YAML)
      targets:
        - name: backend
          kind: repo_check
          run: bin/check-backend
          sources: ["app/**/*.rb"]
          ci_checks: ["Backend CI"]
    YAML

    result = call([{ name: "Backend CI", status: "completed", conclusion: "failure", html_url: "https://github.test/run/1" }])

    expect(result.missed_edges).to contain_exactly(
      include(
        "head_sha" => head_sha,
        "check_name" => "Backend CI",
        "check_url" => "https://github.test/run/1",
        "target_label" => "//:backend",
        "selection_reason" => "no matching files changed",
        "selection_workflow_id" => prior.id,
        "selection_workflow_trigger_kind" => "landing_validation",
        "target_fingerprints" => { "input_fingerprint" => "fp" },
        "dedupe_key" => "#{job.id}:#{head_sha}:Backend CI://:backend"
      )
    )
    expect(prior.reload.artifact(Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY)).to be_present
  end

  def call(checks)
    described_class.call(
      job: job,
      head_sha: head_sha,
      failed_checks: checks,
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

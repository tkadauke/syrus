require "rails_helper"

RSpec.describe WorkflowTemplates do
  let(:repo) { Factories.repository }
  let(:built_in) { [ { "kind" => "implement" }, { "kind" => "pr_open" } ] }

  def with_repo_file(content)
    client = instance_double(GithubClient)
    allow(client).to receive(:file_content_at).and_return(content)
    described_class.for(
      key: "initial", built_in_graph: built_in, repository: repo,
      client: client, resolve_overrides: true
    )
  end

  it "returns the built-in graph and records its provenance" do
    resolution = described_class.for(key: "initial", built_in_graph: built_in)

    expect(resolution).to be_built_in
    expect(resolution.graph).to eq(built_in)
    expect(resolution.provenance).to eq("template_key" => "initial", "template_source" => "built_in")
  end

  # Every workflow instantiation is a hot path; it should not grow a
  # synchronous network call for a file that almost never exists.
  it "does not look for a repo-local template unless asked" do
    client = instance_double(GithubClient)
    expect(client).not_to receive(:file_content_at)

    described_class.for(key: "initial", built_in_graph: built_in, repository: repo, client: client)
  end

  it "prefers a repo-local template and records where it came from" do
    resolution = with_repo_file(<<~YAML)
      - kind: implement
      - kind: adversarial_review
      - kind: pr_open
    YAML

    expect(resolution).to be_repo_override
    expect(resolution.provenance["template_path"]).to eq(".syrus/workflows/initial.yml")
    expect(described_class.step_kinds_in(resolution.graph)).to include("adversarial_review")
  end

  describe "repo-local templates may only add checks" do
    it "refuses one that drops a publication step" do
      resolution = with_repo_file("- kind: implement\n")

      expect(resolution).to be_built_in
    end

    # A repository cannot grant itself a landing step by writing a file.
    it "refuses one that introduces a publication step the built-in lacked" do
      resolution = described_class.for(
        key: "initial", built_in_graph: [ { "kind" => "implement" } ], repository: repo,
        client: instance_double(GithubClient, file_content_at: "- kind: implement\n- kind: auto_merge\n"),
        resolve_overrides: true
      )

      expect(resolution).to be_built_in
    end

    it "refuses one naming a step kind that does not exist" do
      resolution = with_repo_file("- kind: implement\n- kind: summon_daemon\n- kind: pr_open\n")

      expect(resolution).to be_built_in
    end

    it "refuses unparseable YAML rather than running something unintended" do
      resolution = with_repo_file("- kind: [unclosed\n")

      expect(resolution).to be_built_in
    end
  end

  # A GitHub outage means "we do not know what this repository wants", which is
  # the built-in, not a guess.
  it "falls back to the built-in when the repository cannot be read" do
    client = instance_double(GithubClient)
    allow(client).to receive(:file_content_at).and_raise(Octokit::ServiceUnavailable)

    resolution = described_class.for(
      key: "initial", built_in_graph: built_in, repository: repo,
      client: client, resolve_overrides: true
    )

    expect(resolution).to be_built_in
  end

  it "refuses a key that is not a plain template name" do
    expect { described_class.for(key: "../../etc/passwd", built_in_graph: built_in) }
      .to raise_error(ArgumentError, /invalid template key/)
  end

  it "finds step kinds nested inside loop and try nodes" do
    graph = [ { "type" => "loop", "steps" => [ { "kind" => "implement" } ] },
              { "type" => "try", "on_failure" => { "x" => [ { "kind" => "push" } ] } } ]

    expect(described_class.step_kinds_in(graph)).to contain_exactly("implement", "push")
  end
end

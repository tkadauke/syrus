require "rails_helper"

RSpec.describe "plugin capability contexts" do
  it "exposes immutable repository, workspace, grader, and job values" do
    repository = Object.new
    job = Object.new
    repo = Syrus::Plugin::Context::RepoContext.new(repo_path: "/repo", repository:)
    workspace = Syrus::Plugin::Context::WorkspaceContext.new(
      workspace_path: "/work", changed_files: [ "app.rb" ], repository:
    )
    grader = Syrus::Plugin::Context::GraderContext.new(
      name: "rspec", command: "bin/rspec", workspace_path: "/work", failed_cases: [ "one" ],
      base_retry: false, project_path: ""
    )
    job_context = Syrus::Plugin::Context::JobContext.new(repository:, job:)

    expect(repo).to have_attributes(repo_path: "/repo", repository:)
    expect(workspace).to have_attributes(workspace_path: "/work", changed_files: [ "app.rb" ], repository:)
    expect(grader).to have_attributes(name: "rspec", command: "bin/rspec", failed_cases: [ "one" ], base_retry: false)
    expect(job_context).to have_attributes(repository:, job:)
    expect([ repo, workspace, grader, job_context ]).to all(be_frozen)
    expect(workspace.changed_files).to be_frozen
    expect(grader.failed_cases).to be_frozen
  end

  it "keeps an existing capability compatible when core adds a context field" do
    original_context = Data.define(:repo_path, :repository)
    expanded_context = Data.define(:repo_path, :repository, :configuration)
    provider = Class.new do
      def self.detect(context) = context.repo_path
    end

    expect(provider.detect(original_context.new(repo_path: "/repo", repository: nil))).to eq("/repo")
    expect(provider.detect(expanded_context.new(repo_path: "/repo", repository: nil, configuration: {}))).to eq("/repo")
  end
end

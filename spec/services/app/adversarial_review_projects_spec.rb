require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::AdversarialReviewProjects do
  let(:workspace) { Pathname.new(Dir.mktmpdir("syrus-adversarial-review-projects")) }

  after { FileUtils.rm_rf(workspace) }

  def write(path, content)
    full_path = workspace.join(path)
    FileUtils.mkdir_p(full_path.dirname)
    full_path.write(content)
  end

  it "preserves root criteria for a root-only repository" do
    write(".syrus.yml", <<~YAML)
      adversarial_review:
        rounds: 1
        criteria:
          - Keep API errors generic
    YAML

    result = described_class.call(workspace_path: workspace, changed_files: [ "app/models/job.rb" ])

    expect(result.criteria).to eq([ "Keep API errors generic" ])
    expect(result.to_a).to eq([
      {
        "id" => "repo",
        "label" => "Repository",
        "path" => "",
        "owner_config_path" => ".syrus.yml",
        "criteria" => [ "Keep API errors generic" ]
      }
    ])
  end

  it "returns criteria for an affected nested project" do
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
        label: Web
      adversarial_review:
        rounds: 1
        criteria:
          - Verify UI authorization checks
    YAML
    write("apps/api/.syrus.yml", <<~YAML)
      project:
        id: api
      adversarial_review:
        rounds: 1
        criteria:
          - Verify API authorization checks
    YAML

    result = described_class.call(workspace_path: workspace, changed_files: [ "apps/web/src/App.tsx" ])

    expect(result.criteria).to eq([ "Verify UI authorization checks" ])
    expect(result.to_a.first).to include(
      "id" => "web",
      "label" => "Web",
      "path" => "apps/web",
      "owner_config_path" => "apps/web/.syrus.yml"
    )
  end

  it "unions repo-wide root criteria with affected project criteria" do
    write(".syrus.yml", <<~YAML)
      adversarial_review:
        rounds: 1
        criteria:
          - Keep API errors generic
    YAML
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
      adversarial_review:
        rounds: 1
        criteria:
          - Verify UI authorization checks
    YAML

    result = described_class.call(workspace_path: workspace, changed_files: [ "apps/web/src/App.tsx" ])

    expect(result.criteria).to eq([
      "Keep API errors generic",
      "Verify UI authorization checks"
    ])
    expect(result.to_a.map { |project| project["id"] }).to eq(%w[repo web])
  end

  it "deduplicates identical criteria across root and project scopes" do
    write(".syrus.yml", <<~YAML)
      adversarial_review:
        rounds: 1
        criteria:
          - Keep API errors generic
    YAML
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
      adversarial_review:
        rounds: 1
        criteria:
          - Keep API errors generic
          - Verify UI authorization checks
    YAML

    result = described_class.call(workspace_path: workspace, changed_files: [ "apps/web/src/App.tsx" ])

    expect(result.criteria).to eq([
      "Keep API errors generic",
      "Verify UI authorization checks"
    ])
  end
end

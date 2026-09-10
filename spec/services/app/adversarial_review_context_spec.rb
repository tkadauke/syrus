require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::AdversarialReviewContext do
  let(:workspace) { Pathname.new(Dir.mktmpdir("syrus-adversarial-review-context")) }

  after { FileUtils.rm_rf(workspace) }

  def write(path, content)
    full_path = workspace.join(path)
    FileUtils.mkdir_p(full_path.dirname)
    full_path.write(content)
  end

  def diff_for(*paths)
    paths.map { |path| "diff --git a/#{path} b/#{path}\n+changed\n" }.join
  end

  it "preserves root adversarial review criteria for a root-only repository" do
    write(".syrus.yml", <<~YAML)
      adversarial_review:
        rounds: 1
        criteria:
          - Verify authentication checks.
          - Keep error payloads sanitized.
    YAML

    result = described_class.call(
      workspace_path: workspace,
      diff: diff_for("app/controllers/orders_controller.rb")
    )

    expect(result.criteria).to eq([
      "Verify authentication checks.",
      "Keep error payloads sanitized."
    ])
    expect(result.projects.map(&:to_h)).to eq([
      {
        "id" => "repo",
        "label" => "Repository",
        "path" => "",
        "owner_config_path" => ".syrus.yml",
        "criteria" => [
          "Verify authentication checks.",
          "Keep error payloads sanitized."
        ]
      }
    ])
  end

  it "includes project criteria when that project is affected" do
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
        label: Web App
      adversarial_review:
        rounds: 1
        criteria:
          - Check client-side authorization does not replace server checks.
    YAML
    write("apps/api/.syrus.yml", <<~YAML)
      project:
        id: api
      adversarial_review:
        rounds: 1
        criteria:
          - Check API pagination remains stable.
    YAML

    result = described_class.call(
      workspace_path: workspace,
      diff: diff_for("apps/web/src/App.tsx")
    )

    expect(result.criteria).to eq([
      "Check client-side authorization does not replace server checks."
    ])
    expect(result.projects.map(&:id)).to eq([ "web" ])
    expect(result.projects.first.to_h).to include(
      "label" => "Web App",
      "path" => "apps/web",
      "owner_config_path" => "apps/web/.syrus.yml"
    )
  end

  it "unions root and affected project criteria" do
    write(".syrus.yml", <<~YAML)
      adversarial_review:
        rounds: 1
        criteria:
          - Verify authorization boundaries.
    YAML
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
      adversarial_review:
        rounds: 1
        criteria:
          - Check React state survives refreshes.
    YAML

    result = described_class.call(
      workspace_path: workspace,
      diff: diff_for("apps/web/src/App.tsx")
    )

    expect(result.criteria).to eq([
      "Verify authorization boundaries.",
      "Check React state survives refreshes."
    ])
    expect(result.projects.map(&:id)).to eq(%w[repo web])
  end

  it "does not include criteria from unaffected nested projects" do
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
      adversarial_review:
        rounds: 1
        criteria:
          - Check browser routing.
    YAML

    result = described_class.call(
      workspace_path: workspace,
      diff: diff_for("docs/README.md")
    )

    expect(result.criteria).to eq([])
    expect(result.projects).to eq([])
  end

  it "deduplicates identical criteria across root and project declarations" do
    write(".syrus.yml", <<~YAML)
      adversarial_review:
        rounds: 1
        criteria:
          - Verify authorization boundaries.
    YAML
    write("apps/api/.syrus.yml", <<~YAML)
      project:
        id: api
      adversarial_review:
        rounds: 1
        criteria:
          - Verify authorization boundaries.
          - Check API pagination remains stable.
    YAML

    result = described_class.call(
      workspace_path: workspace,
      diff: diff_for("apps/api/controllers/orders_controller.rb")
    )

    expect(result.criteria).to eq([
      "Verify authorization boundaries.",
      "Check API pagination remains stable."
    ])
  end
end

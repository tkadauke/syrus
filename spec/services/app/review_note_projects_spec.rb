require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::ReviewNoteProjects do
  let(:workspace) { Pathname.new(Dir.mktmpdir("syrus-review-note-projects")) }

  after { FileUtils.rm_rf(workspace) }

  def write(path, content)
    full_path = workspace.join(path)
    FileUtils.mkdir_p(full_path.dirname)
    full_path.write(content)
  end

  it "preserves root policy for a root-only repository" do
    write(".syrus.yml", <<~YAML)
      review_notes:
        criteria:
          - Surface shared services
        low_signal:
          - Ignore ordinary tests
    YAML

    result = described_class.call(workspace_path: workspace, changed_files: [ "app/models/job.rb" ])

    expect(result.criteria).to eq([ "Surface shared services" ])
    expect(result.low_signal).to eq([ "Ignore ordinary tests" ])
    expect(result.to_a).to eq([
      {
        "id" => "repo",
        "label" => "Repository",
        "path" => "",
        "owner_config_path" => ".syrus.yml",
        "criteria" => [ "Surface shared services" ],
        "low_signal" => [ "Ignore ordinary tests" ]
      }
    ])
  end

  it "unions root and all affected nested policies" do
    write(".syrus.yml", <<~YAML)
      review_notes:
        criteria:
          - Surface shared services
        low_signal:
          - Ignore ordinary tests
    YAML
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
      review_notes:
        criteria:
          - Surface shared hooks
        low_signal:
          - Ignore snapshots unless they change risk
    YAML
    write("apps/api/.syrus.yml", <<~YAML)
      project:
        id: api
      review_notes:
        criteria:
          - Surface API lifecycle changes
        low_signal:
          - Ignore ordinary tests
    YAML
    write("apps/mobile/.syrus.yml", <<~YAML)
      project:
        id: mobile
      review_notes:
        criteria:
          - Surface native bridge changes
    YAML

    result = described_class.call(
      workspace_path: workspace,
      changed_files: [ "apps/web/src/App.tsx", "apps/api/app/controllers/widgets_controller.rb" ]
    )

    expect(result.criteria).to eq([
      "Surface shared services",
      "Surface API lifecycle changes",
      "Surface shared hooks"
    ])
    expect(result.low_signal).to eq([
      "Ignore ordinary tests",
      "Ignore snapshots unless they change risk"
    ])
    expect(result.to_a.map { |project| project["id"] }).to eq(%w[repo api web])
  end
end

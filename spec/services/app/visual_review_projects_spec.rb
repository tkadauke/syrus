require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::VisualReviewProjects do
  let(:workspace) { Pathname.new(Dir.mktmpdir("syrus-visual-review-projects")) }

  after { FileUtils.rm_rf(workspace) }

  def write(path, content)
    full_path = workspace.join(path)
    FileUtils.mkdir_p(full_path.dirname)
    full_path.write(content)
  end

  it "preserves root preview behavior for a root-only repository" do
    allow(Feature).to receive(:visual_review_enabled?).and_return(true)
    write(".syrus.yml", <<~YAML)
      preview:
        start: bin/dev
      visual_review:
        seed_notes: Open /dashboard.
    YAML

    result = described_class.call(workspace_path: workspace, changed_files: [ "app/views/home/index.html.erb" ])

    expect(result.choices.map(&:id)).to eq([ "repo" ])
    expect(result.choices.first.seed_notes).to eq("Open /dashboard.")
    expect(result.unavailable_reason).to be_nil
  end

  it "returns the one affected nested visual-review-enabled preview project" do
    allow(Feature).to receive(:visual_review_enabled?).and_return(false)
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
        label: Web
      preview:
        start: npm run dev
      visual_review:
        enabled: true
        when_files_changed:
          - src/**/*
        seed_notes: Use the demo account.
    YAML
    write("apps/api/.syrus.yml", <<~YAML)
      project:
        id: api
      preview:
        start: bin/server
      visual_review:
        enabled: true
    YAML

    result = described_class.call(workspace_path: workspace, changed_files: [ "apps/web/src/App.tsx" ])

    expect(result.choices.map(&:id)).to eq([ "web" ])
    expect(result.seed_notes).to eq("Use the demo account.")
    expect(result.when_files_changed).to eq([ "apps/web/src/**/*" ])
  end

  it "returns multiple affected preview projects and unions their visual review filters" do
    allow(Feature).to receive(:visual_review_enabled?).and_return(true)
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
      preview:
        start: npm run dev
      visual_review:
        when_files_changed:
          - src/**/*
    YAML
    write("apps/admin/.syrus.yml", <<~YAML)
      project:
        id: admin
      preview:
        start: npm run admin
      visual_review:
        when_files_changed:
          - app/**/*
    YAML

    result = described_class.call(
      workspace_path: workspace,
      changed_files: [ "apps/web/src/App.tsx", "apps/admin/app/Dashboard.tsx" ]
    )

    expect(result.choices.map(&:id)).to match_array(%w[web admin])
    expect(result.when_files_changed).to match_array([ "apps/web/src/**/*", "apps/admin/app/**/*" ])
  end

  it "reports when no affected project has a preview" do
    allow(Feature).to receive(:visual_review_enabled?).and_return(true)
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
      preview:
        start: npm run dev
    YAML

    result = described_class.call(workspace_path: workspace, changed_files: [ "docs/readme.md" ])

    expect(result.choices).to eq([])
    expect(result.unavailable_reason).to eq("no_affected_preview_project")
  end

  it "reports when affected preview projects explicitly disable visual review" do
    allow(Feature).to receive(:visual_review_enabled?).and_return(true)
    write("apps/web/.syrus.yml", <<~YAML)
      project:
        id: web
      preview:
        start: npm run dev
      visual_review:
        enabled: false
    YAML

    result = described_class.call(workspace_path: workspace, changed_files: [ "apps/web/src/App.tsx" ])

    expect(result.choices).to eq([])
    expect(result.unavailable_reason).to eq("no_affected_visual_review_project")
  end
end

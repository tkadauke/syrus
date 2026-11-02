require "rails_helper"

RSpec.describe App::VisualReviewRuntimeTargets do
  it "selects configured provider targets by changed files" do
    Dir.mktmpdir do |dir|
      File.write(Pathname(dir).join(".syrus.yml"), <<~YAML)
        visual_review:
          targets:
            - name: Terminal UI
              provider: cli_tui
              dimensions: { columns: 100, rows: 32 }
              launch: { command: bin/tui }
              review_notes: Open the queue view
              when_files_changed: ["cli/**"]
              captures: ["queue loaded", "job selected"]
            - name: Web
              provider: browser
              when_files_changed: ["app/frontend/**"]
      YAML

      result = described_class.call(
        workspace_path: dir,
        changed_files: [ "cli/main.go" ],
        preview_projects: App::VisualReviewProjects::Result.new(choices: [], unavailable_reason: "no_preview_configured")
      )

      expect(result.sole).to have_attributes(
        name: "Terminal UI",
        provider: "cli_tui",
        dimensions: { "columns" => 100, "rows" => 32 },
        captures: [ "queue loaded", "job selected" ],
        legacy_browser: false
      )
    end
  end

  it "translates existing preview projects into browser provider targets" do
    previews = App::VisualReviewProjects::Result.new(
      choices: [
        App::VisualReviewProjects::Choice.new(
          id: "web", label: "Web", path: "apps/web", owner_config_path: "apps/web/.syrus.yml",
          seed_notes: "Use demo login", when_files_changed: [ "apps/web/**" ]
        )
      ],
      unavailable_reason: nil
    )

    Dir.mktmpdir do |dir|
      target = described_class.call(workspace_path: dir, changed_files: [ "apps/web/app.tsx" ], preview_projects: previews).sole

      expect(target).to have_attributes(
        provider: "browser",
        workspace_path: Pathname(dir).join("apps/web").to_s,
        review_notes: "Use demo login",
        legacy_browser: true
      )
    end
  end
end

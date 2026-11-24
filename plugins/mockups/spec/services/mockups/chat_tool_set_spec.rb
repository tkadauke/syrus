require "rails_helper"

RSpec.describe Mockups::ChatToolSet do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:workspace_root) { Pathname.new(Dir.mktmpdir("syrus-preview-tools")) }
  let(:tool_set) { described_class.new }

  before do
    allow(ChatWorkspace).to receive(:path_for).and_call_original
    allow(ChatWorkspace).to receive(:path_for).with(chat_session).and_return(workspace_root)
  end

  after { FileUtils.rm_rf(workspace_root) }

  def call(tool_name, params, session: chat_session)
    tool_set.handle(tool_name, params, session ? { chat_session: session } : {})
  end

  def json(response)
    JSON.parse(response.content.first[:text])
  end

  describe ".available_for?" do
    it "is available for a planning-mode (default) chat session at essential/deferred tiers" do
      expect(described_class.available_for?(chat_session, tier: :essential)).to be true
      expect(described_class.available_for?(chat_session, tier: :deferred)).to be true
    end

    it "is unavailable for a coding-mode chat session" do
      chat_session.update!(mode: "coding")

      expect(described_class.available_for?(chat_session, tier: :essential)).to be false
    end

    it "is unavailable for a local-mode chat session" do
      chat_session.update!(mode: "local")

      expect(described_class.available_for?(chat_session, tier: :essential)).to be false
    end
  end

  describe ".tool_definitions" do
    it "exposes the write/edit/show/close tool names" do
      names = described_class.tool_definitions(tier: :essential).map { |tool| tool.fetch(:name) }

      expect(names).to contain_exactly("write_preview_file", "edit_preview_file", "show_preview", "close_preview", "inspect_preview_versions")
    end

    it "describes show_preview as the preferred preview mockup submission flow" do
      show_preview = described_class.tool_definitions(tier: :essential).find { |tool| tool.fetch(:name) == "show_preview" }

      description = show_preview.fetch(:description)
      expect(description).to include("Primary tool for operator-facing UI mockups, HTML mockups, HTML previews")
      expect(description).to include("HTML prototypes", "screenshot-driven redesigns", "open-preview requests")
      expect(description).to include("Canonical sequence")
      expect(description).to include("write index.html and any assets with write_preview_file or edit_preview_file")
      expect(description).to include("call show_preview again with the same panel_id to publish")
      expect(description).to include("Do not use local HTTP servers, local file paths, or workspace-only HTML")
      expect(description).to include("Do not use imagegen for HTML/UI mockups")
      expect(description).to include("Do not tell the user the preview is visible until the publish call")
      expect(description).to include("panel_id, version_id, and mockup_slug")
    end

    it "keeps preview tools discoverable for deferred mockup and prototype searches" do
      search_terms = %w[mockup HTML preview prototype open-preview]

      matching_names = described_class.tool_definitions(tier: :deferred).filter_map do |tool|
        haystack = "#{tool.fetch(:name)} #{tool.fetch(:description)}"
        tool.fetch(:name) if search_terms.all? { |term| haystack.match?(/#{Regexp.escape(term)}/i) }
      end

      expect(matching_names).to include("show_preview", "write_preview_file", "edit_preview_file")
    end

    it "describes write_preview_file with the canonical sequence and anti-patterns" do
      write_preview = described_class.tool_definitions(tier: :essential).find { |tool| tool.fetch(:name) == "write_preview_file" }

      description = write_preview.fetch(:description)
      expect(description).to include("UI mockups", "HTML mockups", "HTML previews", "prototypes")
      expect(description).to include("Canonical sequence")
      expect(description).to include("call show_preview again with the same panel_id to publish")
      expect(description).to include("Do not use local HTTP servers, local file paths, or workspace-only HTML")
      expect(description).to include("Do not use imagegen for HTML/UI mockups")
    end
  end

  describe "#handle" do
    it "errors when there is no chat session in context" do
      response = call("show_preview", { title: "Widget" }, session: nil)

      expect(response.error?).to be true
      expect(response.content.first[:text]).to match(/No chat session/)
    end

    it "errors for an unknown tool name" do
      response = call("delete_everything", {})

      expect(response.error?).to be true
      expect(response.content.first[:text]).to match(/Unknown preview tool/)
    end

    describe "show_preview without panel_id" do
      it "opens a new empty panel" do
        response = call("show_preview", { title: "Widget preview" })

        expect(response.error?).to be false
        payload = json(response)
        expect(payload["title"]).to eq("Widget preview")
        expect(payload["state"]).to eq("open")
        expect(payload["file_count"]).to eq(0)
        expect(payload["note"]).to match(/write_preview_file/)
        expect(payload["note"]).to include("Do not tell the operator the preview is visible until")
        expect(payload).not_to have_key("mockup_slug")

        panel = chat_session.preview_panels.find(payload["panel_id"])
        expect(panel.title).to eq("Widget preview")
      end

      it "requires a title" do
        response = call("show_preview", {})

        expect(response.error?).to be true
        expect(response.content.first[:text]).to match(/title is required/)
      end
    end

    describe "write_preview_file / edit_preview_file" do
      let(:panel) { PreviewPanel::Service.open!(chat_session: chat_session, title: "Widget") }

      it "writes a file into the panel's scratch directory" do
        response = call("write_preview_file", { panel_id: panel.id.to_s, path: "index.html", content: "<h1>hi</h1>" })

        expect(response.error?).to be false
        expect(File.read(workspace_root.join("previews", panel.id.to_s, "index.html"))).to eq("<h1>hi</h1>")
      end

      it "errors for a panel that does not exist" do
        response = call("write_preview_file", { panel_id: "99999", path: "index.html", content: "x" })

        expect(response.error?).to be true
        expect(response.content.first[:text]).to match(/No open preview panel/)
      end

      it "errors for a panel that belongs to a different chat session" do
        other_chat = ChatSession.create!(user: user, repository: repository)

        response = call("write_preview_file", { panel_id: panel.id.to_s, path: "index.html", content: "x" }, session: other_chat)

        expect(response.error?).to be true
      end

      it "errors for a path that escapes the scratch directory" do
        response = call("write_preview_file", { panel_id: panel.id.to_s, path: "../../etc/passwd", content: "pwned" })

        expect(response.error?).to be true
        expect(response.content.first[:text]).to match(/outside/)
      end

      it "edits a previously written file" do
        call("write_preview_file", { panel_id: panel.id.to_s, path: "index.html", content: "<h1>hello</h1>" })

        response = call("edit_preview_file", { panel_id: panel.id.to_s, path: "index.html", old_string: "hello", new_string: "goodbye" })

        expect(response.error?).to be false
        expect(File.read(workspace_root.join("previews", panel.id.to_s, "index.html"))).to eq("<h1>goodbye</h1>")
      end
    end

    describe "show_preview with panel_id" do
      let(:panel) { PreviewPanel::Service.open!(chat_session: chat_session, title: "Widget") }

      it "errors when the scratch directory has no files yet" do
        response = call("show_preview", { panel_id: panel.id.to_s, title: "Widget" })

        expect(response.error?).to be true
        expect(response.content.first[:text]).to match(/No files found/)
      end

      it "errors when entry_file is missing from the scratch files" do
        call("write_preview_file", { panel_id: panel.id.to_s, path: "app.js", content: "console.log(1)" })

        response = call("show_preview", { panel_id: panel.id.to_s, title: "Widget" })

        expect(response.error?).to be true
        expect(response.content.first[:text]).to match(/entry_file/)
      end

      it "publishes the scratch directory to the panel" do
        call("write_preview_file", { panel_id: panel.id.to_s, path: "index.html", content: "<h1>hi</h1>" })
        call("write_preview_file", { panel_id: panel.id.to_s, path: "css/app.css", content: "body {}" })

        response = call("show_preview", { panel_id: panel.id.to_s, title: "Widget" })

        expect(response.error?).to be false
        payload = json(response)
        expect(payload["file_count"]).to eq(2)
        expect(payload["version_id"]).to eq(panel.reload.current_version.id)
        expect(payload["mockup_slug"]).to match(/\AMOCKUP-\d+\z/)
        expect(panel.reload.file_for("index.html").download).to eq("<h1>hi</h1>")
        expect(panel.reload.file_for("css/app.css").download).to eq("body {}")
      end

      it "replaces the prior file set rather than appending" do
        call("write_preview_file", { panel_id: panel.id.to_s, path: "index.html", content: "<h1>hi</h1>" })
        call("write_preview_file", { panel_id: panel.id.to_s, path: "old.js", content: "x" })
        call("show_preview", { panel_id: panel.id.to_s, title: "Widget" })

        FileUtils.rm(workspace_root.join("previews", panel.id.to_s, "old.js"))
        call("show_preview", { panel_id: panel.id.to_s, title: "Widget" })

        expect(panel.reload.file_for("old.js")).to be_nil
        expect(panel.reload.file_for("index.html")).to be_present
      end

      it "accepts a custom entry_file that exists in the scratch directory" do
        call("write_preview_file", { panel_id: panel.id.to_s, path: "widget.html", content: "<h1>hi</h1>" })

        response = call("show_preview", { panel_id: panel.id.to_s, title: "Widget", entry_file: "widget.html" })

        expect(response.error?).to be false
        payload = json(response)
        expect(payload["entry_file"]).to eq("widget.html")
        expect(panel.reload.current_version.entry_file).to eq("widget.html")
        expect(panel.file_for("/").download).to eq("<h1>hi</h1>")
      end

      it "errors for a closed panel" do
        PreviewPanel::Service.new(panel).close!

        response = call("show_preview", { panel_id: panel.id.to_s, title: "Widget" })

        expect(response.error?).to be true
        expect(response.content.first[:text]).to match(/No open preview panel/)
      end
    end

    describe "close_preview" do
      it "closes an open panel" do
        panel = PreviewPanel::Service.open!(chat_session: chat_session, title: "Widget")
        mockup = Mockups::Mockup.record_publish!(panel: panel, user: user, title: panel.title, chat_session: chat_session)

        response = call("close_preview", { panel_id: panel.id.to_s })

        expect(response.error?).to be false
        expect(panel.reload.state).to eq("closed")
        expect(JSON.parse(response.content.first[:text])).to include(
          "panel_id" => panel.id,
          "title" => "Widget",
          "state" => "closed",
          "mockup_slug" => mockup.slug
        )
      end

      it "errors for a panel that does not exist" do
        response = call("close_preview", { panel_id: "99999" })

        expect(response.error?).to be true
      end
    end

    describe "inspect_preview_versions" do
      let(:panel) { PreviewPanel::Service.open!(chat_session: chat_session, title: "Widget", files: { "index.html" => "<p>v1</p>", "css/app.css" => "a{}" }) }
      let!(:v1) { panel.current_version }
      let!(:v2) do
        PreviewPanel::Service.new(panel).update!(files: { "index.html" => "<p>v2</p>", "logo.png" => "\x89PNG\x00\x01".b })
        panel.reload.current_version
      end

      it "lists every version with entry path and stored files" do
        data = json(call("inspect_preview_versions", { panel_id: panel.id.to_s }))

        expect(data["current_version_id"]).to eq(v2.id)
        expect(data["versions"].map { |v| v["version_id"] }).to eq([ v2.id, v1.id ])
        old = data["versions"].last
        expect(old).to include("entry_file" => "index.html", "created_at" => be_present)
        expect(old["files"].map { |f| f["path"] }).to eq(%w[css/app.css index.html])
      end

      it "reads the current version by default and a historical one by id" do
        expect(json(call("inspect_preview_versions", { panel_id: panel.id.to_s, path: "index.html" }))["content"]).to eq("<p>v2</p>")
        old = json(call("inspect_preview_versions", { panel_id: panel.id.to_s, version_id: v1.id.to_s, path: "index.html" }))
        expect(old).to include("content" => "<p>v1</p>", "version_id" => v1.id, "truncated" => false)
        expect(json(call("inspect_preview_versions", { panel_id: panel.id.to_s, version_id: v1.id.to_s, path: "css/app.css" }))["content"]).to eq("a{}")
      end

      it "works for closed panels without changing state or versions" do
        PreviewPanel::Service.new(panel).close!

        expect { call("inspect_preview_versions", { panel_id: panel.id.to_s, version_id: v1.id.to_s, path: "index.html" }) }
          .not_to change { [ panel.reload.state, panel.preview_panel_versions.count, panel.current_version.id ] }
        expect(call("inspect_preview_versions", { panel_id: panel.id.to_s, version_id: v1.id.to_s, path: "index.html" }).error?).to be false
      end

      it "reports binary files as metadata only" do
        data = json(call("inspect_preview_versions", { panel_id: panel.id.to_s, path: "logo.png" }))

        expect(data).to include("binary" => true, "byte_size" => 6)
        expect(data).not_to have_key("content")
      end

      it "truncates large text with metadata" do
        big = "x" * (Mockups::InspectPreviewVersionsTool::MAX_TEXT_BYTES + 10)
        PreviewPanel::Service.new(panel).update!(files: { "index.html" => big })

        data = json(call("inspect_preview_versions", { panel_id: panel.id.to_s, path: "index.html" }))

        expect(data).to include("truncated" => true, "total_bytes" => big.bytesize, "returned_bytes" => Mockups::InspectPreviewVersionsTool::MAX_TEXT_BYTES)
        expect(data["content"].bytesize).to eq(Mockups::InspectPreviewVersionsTool::MAX_TEXT_BYTES)
      end

      it "rejects another chat's panel, foreign versions, and missing paths" do
        other_chat = ChatSession.create!(user: user, repository: repository)
        other_panel = PreviewPanel::Service.open!(chat_session: other_chat, title: "Other", files: { "index.html" => "x" })

        expect(call("inspect_preview_versions", { panel_id: other_panel.id.to_s }).error?).to be true
        expect(call("inspect_preview_versions", { panel_id: "99999" }).error?).to be true
        foreign = call("inspect_preview_versions", { panel_id: panel.id.to_s, version_id: other_panel.current_version.id.to_s, path: "index.html" })
        expect(foreign.error?).to be true
        expect(foreign.content.first[:text]).to include("does not belong")
        missing = call("inspect_preview_versions", { panel_id: panel.id.to_s, path: "nope.html" })
        expect(missing.error?).to be true
        expect(missing.content.first[:text]).to include("not found")
      end

      it "is discoverable by searching for historical versions" do
        tool = described_class.tool_definitions(tier: :deferred).find { |t| t.fetch(:name) == "inspect_preview_versions" }

        expect(tool.fetch(:description)).to include("old, previous, or historical versions", "mockup")
      end
    end
  end
end

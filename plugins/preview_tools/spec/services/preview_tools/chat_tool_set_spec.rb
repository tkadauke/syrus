require "rails_helper"

RSpec.describe PreviewTools::ChatToolSet do
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

      expect(names).to contain_exactly("write_preview_file", "edit_preview_file", "show_preview", "close_preview")
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

        response = call("close_preview", { panel_id: panel.id.to_s })

        expect(response.error?).to be false
        expect(panel.reload.state).to eq("closed")
      end

      it "errors for a panel that does not exist" do
        response = call("close_preview", { panel_id: "99999" })

        expect(response.error?).to be true
      end
    end
  end
end

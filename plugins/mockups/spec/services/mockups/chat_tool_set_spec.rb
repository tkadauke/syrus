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
    it "exposes the write/edit/render/show/close tool names" do
      names = described_class.tool_definitions(tier: :essential).map { |tool| tool.fetch(:name) }

      expect(names).to contain_exactly("write_preview_file", "edit_preview_file", "render_preview", "show_preview", "close_preview")
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

    describe "render_preview" do
      let(:panel) { PreviewPanel::Service.open!(chat_session: chat_session, title: "Widget", files: {}) }
      let(:calls) { [] }
      let(:fake_session) do
        recorded = calls
        Class.new do
          define_method(:initialize) { |fetched| @fetched = fetched }
          define_method(:call_tool) do |name:, arguments:|
            recorded << [ name, arguments ]
            if name == "browser_navigate"
              @fetched << Net::HTTP.get_response(URI(arguments["url"]))
            end
            if name == "browser_take_screenshot"
              { "result" => { "content" => [ { "type" => "image", "data" => "iVBORw0KGgo=", "mimeType" => "image/png" } ] } }
            else
              { "result" => { "content" => [ { "type" => "text", "text" => "ok" } ] } }
            end
          end
          define_method(:close) { recorded << [ :closed ] }
        end
      end
      let(:fetched) { [] }

      before do
        Mockups::PreviewRenderer.session_factory = ->(_key) { fake_session.new(fetched) }
        Mockups::ScratchDirectory.new(chat_session, panel.id).write("index.html", "<h1>Draft</h1>")
      end

      # The renderer's throwaway server is a real loopback socket; VCR would
      # otherwise refuse the fake browser's fetch of it.
      around { |example| VCR.turned_off { example.run } }

      after { Mockups::PreviewRenderer.reset! }

      it "returns a PNG image block plus metadata for the unpublished scratch state" do
        response = call("render_preview", { panel_id: panel.id.to_s })

        expect(response.error?).to be false
        image, text = response.content
        expect(image).to include(type: "image", mimeType: "image/png", data: "iVBORw0KGgo=")
        expect(JSON.parse(text[:text])).to include(
          "panel_id" => panel.id, "entry_file" => "index.html", "preset" => "desktop",
          "viewport" => { "width" => 1280, "height" => 800 }, "capture" => "viewport", "published" => false
        )
        expect(fetched.first.body).to eq("<h1>Draft</h1>")
        expect(fetched.first["Content-Security-Policy"]).to include("default-src")
        expect(calls.last).to eq([ :closed ])
      end

      it "passes presets, explicit dimensions, full page, wait and entry file to the browser" do
        Mockups::ScratchDirectory.new(chat_session, panel.id).write("alt/page.html", "<p>alt</p>")

        call("render_preview", { panel_id: panel.id.to_s, viewport: "mobile", full_page: true, wait_ms: 1500, entry_file: "alt/page.html" })

        expect(calls).to include(
          [ "browser_resize", { "width" => 393, "height" => 852 } ],
          [ "browser_wait_for", { "time" => 1.5 } ],
          [ "browser_take_screenshot", { "type" => "png", "fullPage" => true } ]
        )
        expect(fetched.first.body).to eq("<p>alt</p>")

        calls.clear
        call("render_preview", { panel_id: panel.id.to_s, width: 500, height: 600 })
        expect(calls).to include([ "browser_resize", { "width" => 500, "height" => 600 } ])
        expect(calls.map(&:first)).not_to include("browser_wait_for")
      end

      it "does not publish, version, or broadcast" do
        expect(ActionCable.server).not_to receive(:broadcast)
        expect(Mockups::Mockup).not_to receive(:record_publish!)
        panel.reload

        expect { call("render_preview", { panel_id: panel.id.to_s }) }.not_to change { [ PreviewPanelVersion.count, panel.reload.current_version&.id, Mockups::Mockup.count ] }
      end

      it "rejects out-of-bounds and malformed inputs without starting a browser" do
        [ { width: 100, height: 600 }, { width: 500 }, { width: 500, height: 99_999 }, { viewport: "watch" }, { wait_ms: 60_000 } ].each do |bad|
          response = call("render_preview", { panel_id: panel.id.to_s }.merge(bad))
          expect(response.error?).to be true
        end
        expect(calls).to be_empty
      end

      it "rejects missing, closed, and cross-chat panels" do
        expect(call("render_preview", { panel_id: "99999" }).error?).to be true

        other_chat = ChatSession.create!(user: user, repository: repository)
        expect(call("render_preview", { panel_id: panel.id.to_s }, session: other_chat).error?).to be true

        PreviewPanel::Service.new(panel).close!
        response = call("render_preview", { panel_id: panel.id.to_s })
        expect(response.error?).to be true
        expect(response.content.first[:text]).to match(/No open preview panel/)
        expect(calls).to be_empty
      end

      it "rejects unsafe and missing entry files" do
        outside = workspace_root.join("secret.html")
        File.write(outside, "secret")

        [ "../../secret.html", "/etc/passwd", "nope.html" ].each do |entry|
          response = call("render_preview", { panel_id: panel.id.to_s, entry_file: entry })
          expect(response.error?).to be true
        end
        expect(calls).to be_empty
      end

      it "does not serve files outside the scratch directory or through symlinks" do
        scratch = Mockups::ScratchDirectory.new(chat_session, panel.id)
        File.write(workspace_root.join("secret.html"), "secret")
        File.symlink(workspace_root.join("secret.html"), scratch.root.join("link.html"))
        server = Mockups::PreviewRenderer::ScratchServer.new(scratch)
        begin
          %w[link.html %2e%2e/secret.html missing.html].each do |path|
            expect(Net::HTTP.get_response(URI(server.url_for("index.html").sub("index.html", path))).code).to eq("404")
          end
          expect(Net::HTTP.get_response(URI(server.url_for("index.html"))).code).to eq("200")
        ensure
          server.stop
        end
      end

      it "reports an actionable error when the browser is unavailable" do
        Mockups::PreviewRenderer.session_factory = ->(_key) { raise Mockups::PreviewRenderer::Unavailable, "the Browser plugin is not enabled" }

        response = call("render_preview", { panel_id: panel.id.to_s })

        expect(response.error?).to be true
        expect(response.content.first[:text]).to include("Browser plugin is not enabled", "Publish with show_preview")
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
  end
end

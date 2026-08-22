require "rails_helper"

RSpec.describe PreviewTools::ScratchDirectory do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:workspace_root) { Pathname.new(Dir.mktmpdir("syrus-preview-tools")) }
  let(:scratch) { described_class.new(chat_session, 7) }

  before do
    allow(ChatWorkspace).to receive(:path_for).and_call_original
    allow(ChatWorkspace).to receive(:path_for).with(chat_session).and_return(workspace_root)
  end

  after { FileUtils.rm_rf(workspace_root) }

  describe "#root" do
    it "scopes to previews/<panel_id> under the chat workspace" do
      expect(scratch.root).to eq(workspace_root.join("previews", "7"))
    end
  end

  describe "#write" do
    it "creates the file, including parent directories" do
      scratch.write("css/app.css", "body { color: red; }")

      expect(File.read(workspace_root.join("previews", "7", "css", "app.css"))).to eq("body { color: red; }")
    end

    it "overwrites an existing file" do
      scratch.write("index.html", "<h1>v1</h1>")
      scratch.write("index.html", "<h1>v2</h1>")

      expect(File.read(workspace_root.join("previews", "7", "index.html"))).to eq("<h1>v2</h1>")
    end

    it "rejects a path that escapes the scratch directory via .." do
      expect { scratch.write("../../etc/passwd", "pwned") }.to raise_error(described_class::InvalidPath, /outside/)
    end

    it "rejects an absolute path" do
      expect { scratch.write("/etc/passwd", "pwned") }.to raise_error(described_class::InvalidPath, /outside/)
    end

    it "rejects a blank path" do
      expect { scratch.write("", "content") }.to raise_error(described_class::InvalidPath, /required/)
    end

    it "rejects content over the size limit" do
      huge = "a" * (described_class::MAX_FILE_BYTES + 1)

      expect { scratch.write("index.html", huge) }.to raise_error(described_class::InvalidPath, /limit/)
    end
  end

  describe "#edit" do
    before { scratch.write("index.html", "<h1>hello</h1>") }

    it "replaces a unique old_string with new_string" do
      scratch.edit("index.html", "hello", "goodbye")

      expect(File.read(workspace_root.join("previews", "7", "index.html"))).to eq("<h1>goodbye</h1>")
    end

    it "raises when old_string is not found" do
      expect { scratch.edit("index.html", "missing", "x") }.to raise_error(described_class::InvalidPath, /not found/)
    end

    it "raises when old_string is not unique and replace_all is not set" do
      scratch.write("dup.html", "one one")

      expect { scratch.edit("dup.html", "one", "two") }.to raise_error(described_class::InvalidPath, /appears 2 times/)
    end

    it "replaces every occurrence when replace_all is true" do
      scratch.write("dup.html", "one one")

      scratch.edit("dup.html", "one", "two", replace_all: true)

      expect(File.read(workspace_root.join("previews", "7", "dup.html"))).to eq("two two")
    end

    it "raises when the file does not exist yet" do
      expect { scratch.edit("missing.html", "a", "b") }.to raise_error(described_class::InvalidPath, /does not exist/)
    end
  end

  describe "#exist?" do
    it "is true for a written file" do
      scratch.write("index.html", "hi")

      expect(scratch.exist?("index.html")).to be true
    end

    it "is false for a missing file" do
      expect(scratch.exist?("missing.html")).to be false
    end

    it "is false (not raising) for a path outside the scratch directory" do
      expect(scratch.exist?("../../etc/passwd")).to be false
    end
  end

  describe "#files" do
    it "returns an empty hash when nothing has been written" do
      expect(scratch.files).to eq({})
    end

    it "returns every written file keyed by its relative path" do
      scratch.write("index.html", "<h1>hi</h1>")
      scratch.write("css/app.css", "body {}")

      expect(scratch.files.keys.sort).to eq(%w[css/app.css index.html])
      expect(File.read(scratch.files["index.html"])).to eq("<h1>hi</h1>")
    end
  end
end

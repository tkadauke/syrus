require "rails_helper"
require "tmpdir"

RSpec.describe PreviewLogPath do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      @workspace = File.join(@root, "ws")
      @outside = File.join(@root, "outside")
      FileUtils.mkdir_p([ File.join(@workspace, "log"), @outside ])
      example.run
    end
  end

  it "resolves an existing file inside the workspace" do
    file = File.join(@workspace, "log", "app.log")
    File.write(file, "x")

    expect(described_class.resolve(@workspace, "log/app.log")).to eq(file)
  end

  it "rejects lexical traversal out of the workspace" do
    File.write(File.join(@outside, "secret.log"), "x")

    expect(described_class.resolve(@workspace, "../outside/secret.log")).to be_nil
  end

  it "rejects symlinks that escape the workspace" do
    File.write(File.join(@outside, "secret.log"), "x")
    File.symlink(File.join(@outside, "secret.log"), File.join(@workspace, "link.log"))

    expect(described_class.resolve(@workspace, "link.log")).to be_nil
  end

  it "returns nil for missing files unless allow_missing is set" do
    expect(described_class.resolve(@workspace, "log/new.log")).to be_nil
    expect(described_class.resolve(@workspace, "log/new.log", allow_missing: true))
      .to eq(File.join(@workspace, "log", "new.log"))
  end

  it "resolves missing nested paths under the nearest existing ancestor" do
    expect(described_class.resolve(@workspace, "log/a/b/c.log", allow_missing: true))
      .to eq(File.join(@workspace, "log", "a", "b", "c.log"))
  end

  it "rejects a missing path whose ancestor symlink escapes the workspace" do
    File.symlink(@outside, File.join(@workspace, "esc"))

    expect(described_class.resolve(@workspace, "esc/new.log", allow_missing: true)).to be_nil
  end

  it "honors base_path for relative paths" do
    file = File.join(@workspace, "log", "app.log")
    File.write(file, "x")

    expect(described_class.resolve(@workspace, "app.log", base_path: File.join(@workspace, "log"))).to eq(file)
  end
end

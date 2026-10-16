require "rails_helper"
require "tmpdir"

RSpec.describe ImmutableSourceCheckoutLinkTree do
  around do |example|
    Dir.mktmpdir("syrus-link-tree-spec") do |dir|
      @root = Pathname.new(dir)
      example.run
    end
  end

  let(:source) { @root.join("prepared") }
  let(:destination) { @root.join("checkout") }

  before do
    write(source.join("Gemfile"), "source 'https://rubygems.org'\n")
    write(source.join("app/models/widget.rb"), "class Widget; end\n")
    write(source.join("node_modules/left-pad/index.js"), "module.exports = 1\n")
    write(source.join("vendor/bundle/ruby/gem/lib/gem.rb"), "module Gem; end\n")
    write(source.join("tmp/cache/bootsnap"), "cached\n")
    write(source.join("log/test.log"), "previous run\n")
    write(source.join("storage/test.sqlite3"), "sqlite-bytes\n")
    write(source.join("Gemfile.lock"), "BUNDLED WITH\n   2.5.0\n")
    write(source.join(".syrus/deps/bundle/prepared.txt"), "ready\n")
    write(source.join(".git/index"), "git-index-bytes\n")
    write(source.join("CLAUDE.md"), "# guide\n")
    File.symlink("CLAUDE.md", source.join("AGENTS.md").to_s)
  end

  it "links the dependency trees instead of copying their bytes" do
    result = described_class.link(source: source, destination: destination)

    expect(result).to be_linked
    expect(result.strategy).to eq("hardlink")
    %w[Gemfile app/models/widget.rb node_modules/left-pad/index.js vendor/bundle/ruby/gem/lib/gem.rb].each do |relative|
      expect(File.stat(destination.join(relative)).ino)
        .to eq(File.stat(source.join(relative)).ino), "expected #{relative} to share an inode"
    end
  end

  # link(2) dereferences a symlink on macOS, so a link farm quietly replaced
  # this repository's AGENTS.md -> CLAUDE.md with a copy of CLAUDE.md.
  it "recreates symlinks as symlinks rather than linking what they point at" do
    described_class.link(source: source, destination: destination)

    expect(destination.join("AGENTS.md")).to be_symlink
    expect(File.readlink(destination.join("AGENTS.md").to_s)).to eq("CLAUDE.md")
  end

  it "reproduces the source tree byte for byte" do
    described_class.link(source: source, destination: destination)

    expect(manifest(destination)).to eq(manifest(source))
  end

  # The prepared tree is shared by every grader on the host, so a path a graded
  # run writes *in place* must not reach it.
  it "gives each checkout its own copy of the paths a run writes in place" do
    result = described_class.link(source: source, destination: destination)

    expect(result.unshared_paths).to include(".git", "tmp", "log", "storage", "Gemfile.lock", ".syrus")
    %w[.git/index tmp/cache/bootsnap log/test.log storage/test.sqlite3 Gemfile.lock .syrus/deps/bundle/prepared.txt].each do |relative|
      expect(File.stat(destination.join(relative)).ino)
        .not_to eq(File.stat(source.join(relative)).ino), "expected #{relative} to be unshared"
      expect(destination.join(relative).read).to eq(source.join(relative).read)
    end
  end

  it "keeps the prepared tree intact under the writes a graded run performs" do
    described_class.link(source: source, destination: destination)
    before = manifest(source)

    # Appended in place, the way a log is.
    File.open(destination.join("log/test.log"), "a") { |file| file.write("this run\n") }
    # Truncated in place, the way a sqlite database is.
    File.write(destination.join("storage/test.sqlite3"), "rewritten")
    # Rewritten by a dependency install.
    File.write(destination.join("Gemfile.lock"), "BUNDLED WITH\n   2.6.0\n")
    # Replaced, the way git and bundler write: a new inode over the old name.
    File.write(destination.join("app/models/widget.rb.new"), "class Widget; def call; end; end\n")
    File.rename(destination.join("app/models/widget.rb.new"), destination.join("app/models/widget.rb"))
    # Added, the way an install adds a gem.
    write(destination.join("vendor/bundle/ruby/gem/lib/extra.rb"), "module Extra; end\n")

    expect(manifest(source)).to eq(before)
  end

  # Load-bearing assumption, verified with real git rather than reasoned about:
  # BaseRevisionRetry links the prepared checkout and then moves it to the base
  # revision, which only works because git replaces a file (unlink, then
  # create) instead of writing through to the inode a link shares.
  it "survives a real git checkout in the linked tree without touching the source" do
    source = @root.join("repo")
    FileUtils.mkdir_p(source)
    sh("git -C #{source} init -q -b main")
    sh("git -C #{source} config user.email spec@example.com")
    sh("git -C #{source} config user.name Spec")
    source.join("tracked.rb").write("head revision\n")
    sh("git -C #{source} add tracked.rb")
    sh("git -C #{source} commit -q -m head")
    head_sha = `git -C #{source} rev-parse HEAD`.strip
    source.join("tracked.rb").write("base revision\n")
    sh("git -C #{source} commit -q -am base")
    base_sha = `git -C #{source} rev-parse HEAD`.strip
    sh("git -C #{source} checkout -q #{head_sha}")
    FileUtils.mkdir_p(source.join("vendor/bundle"))
    source.join("vendor/bundle/gem.rb").write("module Gem; end\n")
    expect(source.join("tracked.rb").read).to eq("head revision\n")

    result = described_class.link(source: source, destination: destination)
    expect(result).to be_linked
    sh("git -C #{destination} checkout -q --detach #{base_sha}")

    expect(destination.join("tracked.rb").read).to eq("base revision\n")
    expect(source.join("tracked.rb").read).to eq("head revision\n")
    # The dependencies came along, which is the entire point for a base retry.
    expect(destination.join("vendor/bundle/gem.rb")).to exist
    expect(File.stat(destination.join("vendor/bundle/gem.rb")).ino)
      .to eq(File.stat(source.join("vendor/bundle/gem.rb")).ino)
  end

  it "falls back to a copy when the filesystem refuses links" do
    allow(File).to receive(:link).and_raise(Errno::EXDEV.new("prepared"))

    result = described_class.link(source: source, destination: destination)

    expect(result).not_to be_linked
    expect(result.strategy).to eq("copy")
    expect(result.reason).to include("Errno::EXDEV")
    expect(destination).not_to exist
  end

  it "reports a missing prepared tree rather than raising" do
    result = described_class.link(source: @root.join("absent"), destination: destination)

    expect(result).not_to be_linked
    expect(result.reason).to eq("prepared checkout source is missing")
  end

  def sh(command)
    output = `#{command} 2>&1`
    raise "command failed: #{command}\n#{output}" unless $?.success?

    output
  end

  def write(path, content)
    FileUtils.mkdir_p(path.dirname)
    path.write(content)
  end

  def manifest(root)
    root = Pathname.new(root)
    Dir.chdir(root) do
      Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." }.sort.to_h do |relative|
        path = root.join(relative)
        [ relative, path.file? ? "file:#{Digest::SHA256.file(path).hexdigest}" : "dir" ]
      end
    end
  end
end

require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Ruby::AffectedTestAnalyzer do
  around do |ex|
    Dir.mktmpdir("syrus-ruby-affected-test-analyzer") { |dir| @dir = Pathname.new(dir); ex.run }
  end

  def write(relative_path, content = "")
    path = @dir.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.write(content)
  end

  describe ".affected_files" do
    it "declines (returns nil) when the diff touches no Ruby files" do
      expect(described_class.affected_files(repo_path: @dir, changed_files: [ "README.md" ])).to be_nil
    end

    it "returns [] when a changed file's own spec does not exist" do
      write("app/models/widget.rb", "class Widget; end\n")

      result = described_class.affected_files(repo_path: @dir, changed_files: [ "app/models/widget.rb" ])

      expect(result).to eq([])
    end

    it "maps a changed app/ file to its own conventional spec via the app<->spec mirror" do
      write("app/models/widget.rb", "class Widget; end\n")
      write("spec/models/widget_spec.rb", "")

      result = described_class.affected_files(repo_path: @dir, changed_files: [ "app/models/widget.rb" ])

      expect(result).to eq([ "spec/models/widget_spec.rb" ])
    end

    it "maps a changed lib/ file to its own conventional spec under spec/lib" do
      write("lib/foo.rb", "")
      write("spec/lib/foo_spec.rb", "")

      result = described_class.affected_files(repo_path: @dir, changed_files: [ "lib/foo.rb" ])

      expect(result).to eq([ "spec/lib/foo_spec.rb" ])
    end

    it "follows require_relative reverse-dependency edges to affect a dependent file's own spec" do
      # bar.rb require_relative's foo.rb; a change to foo.rb should also
      # affect bar's own spec, even though bar.rb itself never appears in
      # the diff and no glob on foo.rb's path alone would ever catch this.
      write("lib/foo.rb", "")
      write("lib/bar.rb", "require_relative \"foo\"\n")
      write("spec/lib/bar_spec.rb", "")

      result = described_class.affected_files(repo_path: @dir, changed_files: [ "lib/foo.rb" ])

      expect(result).to contain_exactly("spec/lib/bar_spec.rb")
    end

    it "resolves require_relative targets that walk up a directory with ../" do
      write("lib/foo.rb", "")
      write("lib/nested/bar.rb", "require_relative \"../foo\"\n")
      write("spec/lib/nested/bar_spec.rb", "")

      result = described_class.affected_files(repo_path: @dir, changed_files: [ "lib/foo.rb" ])

      expect(result).to contain_exactly("spec/lib/nested/bar_spec.rb")
    end

    it "declines when the repo's app/lib source tree exceeds the confidence threshold" do
      stub_const("Ruby::AffectedTestAnalyzer::MAX_SOURCE_FILES", 0)
      write("lib/foo.rb", "")

      result = described_class.affected_files(repo_path: @dir, changed_files: [ "lib/foo.rb" ])

      expect(result).to be_nil
    end

    it "rescues unexpected errors by declining rather than raising" do
      allow(Dir).to receive(:glob).and_raise(Errno::ENOENT)

      result = described_class.affected_files(repo_path: @dir, changed_files: [ "lib/foo.rb" ])

      expect(result).to be_nil
    end
  end
end

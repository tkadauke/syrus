require "rails_helper"

RSpec.describe GitInfoExclude do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = Pathname.new(dir)
      FileUtils.mkdir_p(@tmpdir.join(".git", "info"))
      example.run
    end
  end

  let(:exclude_path) { @tmpdir.join(".git", "info", "exclude") }

  describe ".ensure_entry!" do
    it "creates the exclude file with the entry when it does not exist" do
      described_class.ensure_entry!(@tmpdir.to_s, ".syrus")

      expect(exclude_path.read).to include(".syrus")
    end

    it "appends an entry to an existing exclude file that does not contain it" do
      exclude_path.write("*.log\n")

      described_class.ensure_entry!(@tmpdir.to_s, ".syrus")

      content = exclude_path.read
      expect(content).to include("*.log")
      expect(content).to include(".syrus")
    end

    it "does not duplicate an entry already present in the file" do
      exclude_path.write(".syrus\n")

      described_class.ensure_entry!(@tmpdir.to_s, ".syrus")

      occurrences = exclude_path.read.lines.count { |l| l.chomp == ".syrus" }
      expect(occurrences).to eq(1)
    end

    it "separates the new entry from existing content with a newline when the file lacks one" do
      exclude_path.write("*.log")

      described_class.ensure_entry!(@tmpdir.to_s, ".syrus")

      lines = exclude_path.read.lines.map(&:chomp)
      expect(lines).to include("*.log")
      expect(lines).to include(".syrus")
      # Ensure they are on separate lines
      expect(lines.index("*.log")).not_to eq(lines.index(".syrus"))
    end
  end
end

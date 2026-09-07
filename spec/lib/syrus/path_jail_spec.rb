require "rails_helper"

RSpec.describe Syrus::PathJail do
  let(:root) { Pathname.new(Dir.mktmpdir("syrus-path-jail")) }

  after { FileUtils.rm_rf(root.to_s) }

  describe ".resolve!" do
    it "resolves a simple relative path under root" do
      resolved = described_class.resolve!(root, "css/app.css")

      expect(resolved).to eq(root.join("css/app.css"))
    end

    it "cleans redundant path segments that stay inside root" do
      resolved = described_class.resolve!(root, "css/../js/./app.js")

      expect(resolved).to eq(root.join("js/app.js"))
    end

    it "raises PathEscape for a blank relative path" do
      expect { described_class.resolve!(root, "") }.to raise_error(described_class::PathEscape) do |error|
        expect(error.reason).to eq(:blank)
      end
    end

    it "raises PathEscape for a nil relative path" do
      expect { described_class.resolve!(root, nil) }.to raise_error(described_class::PathEscape) do |error|
        expect(error.reason).to eq(:blank)
      end
    end

    it "raises PathEscape for ../ traversal that leaves root" do
      expect { described_class.resolve!(root, "../../etc/passwd") }.to raise_error(described_class::PathEscape) do |error|
        expect(error.reason).to eq(:escape)
      end
    end

    it "raises PathEscape for traversal that returns to a sibling of root" do
      sibling_name = "#{root.basename}-sibling"
      expect { described_class.resolve!(root, "../#{sibling_name}/secret") }.to raise_error(described_class::PathEscape)
    end

    it "raises PathEscape for absolute-path injection" do
      expect { described_class.resolve!(root, "/etc/passwd") }.to raise_error(described_class::PathEscape) do |error|
        expect(error.reason).to eq(:escape)
      end
    end

    it "raises PathEscape when the relative path resolves to root itself" do
      expect { described_class.resolve!(root, ".") }.to raise_error(described_class::PathEscape) do |error|
        expect(error.reason).to eq(:escape)
      end
    end

    it "raises PathEscape when the relative path resolves to root via traversal" do
      expect { described_class.resolve!(root, "sub/..") }.to raise_error(described_class::PathEscape)
    end

    it "does not treat a sibling directory sharing root's name as a prefix as inside root" do
      sibling = Pathname.new("#{root}-evil")

      expect { described_class.resolve!(root, sibling.to_s) }.to raise_error(described_class::PathEscape)
    end

    it "resolves a path that points at a symlink target still inside root, without following it" do
      target = root.join("real.txt")
      File.write(target.to_s, "hi")
      link = root.join("link.txt")
      FileUtils.ln_s(target.to_s, link.to_s)

      resolved = described_class.resolve!(root, "link.txt")

      expect(resolved).to eq(root.join("link.txt"))
    end

    it "accepts an absolute relative_path that is already inside root" do
      resolved = described_class.resolve!(root, root.join("nested/file.txt").to_s)

      expect(resolved).to eq(root.join("nested/file.txt"))
    end
  end
end

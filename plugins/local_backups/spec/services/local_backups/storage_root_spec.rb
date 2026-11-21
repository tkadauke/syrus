require "rails_helper"
require_relative "../../support/resolved_tmpdir"

RSpec.describe LocalBackups::StorageRoot do
  it "contains artifact paths and rejects traversal and symlink escapes" do
    Dir.mktmpdir do |parent|
      root = Pathname.new(parent).join("backups").tap(&:mkpath)
      root.join("sealed").mkpath
      outside = Pathname.new(parent).join("outside").tap(&:mkpath)
      root.join("escape").make_symlink(outside)
      storage = described_class.new(configured: root.to_s)

      expect(storage.contained("sealed")).to eq(root.join("sealed").realpath)
      expect { storage.contained("../outside") }.to raise_error(described_class::Invalid)
      expect { storage.contained("escape") }.to raise_error(described_class::Invalid)
    end
  end

  it "rejects unsafe nesting with the primary data root" do
    Dir.mktmpdir do |parent|
      data = Pathname.new(parent).join("data").tap(&:mkpath)
      backups = data.join("backups").tap(&:mkpath)
      expect { described_class.new(configured: backups.to_s, data_root: data.to_s) }.to raise_error(described_class::Invalid)
    end
  end
end

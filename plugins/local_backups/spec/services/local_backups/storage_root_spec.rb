require "rails_helper"

RSpec.describe LocalBackups::StorageRoot do
  it "requires an absolute existing path outside the data root" do
    expect { described_class.new("relative") }.to raise_error(described_class::Error, /absolute/)
    Dir.mktmpdir do |dir|
      data = Pathname(dir).join("data").tap(&:mkpath)
      backup = data.join("backups").tap(&:mkpath)
      expect { described_class.new(backup, data_root: data) }.to raise_error(described_class::Error, /may not be nested/)
    end
  end

  it "rejects symlink roots and symlink escapes beneath the root" do
    Dir.mktmpdir do |dir|
      base = Pathname(dir)
      root = base.join("backups").tap(&:mkpath)
      outside = base.join("outside").tap(&:mkpath)
      root.join("escape").make_symlink(outside)
      storage = described_class.new(root)

      expect { storage.contain!(root.join("escape")) }.to raise_error(described_class::Error, /symlink|escapes/)
      root_link = base.join("backup-link").tap { |path| path.make_symlink(root) }
      expect { described_class.new(root_link) }.to raise_error(described_class::Error, /symlinks/)
    end
  end
end

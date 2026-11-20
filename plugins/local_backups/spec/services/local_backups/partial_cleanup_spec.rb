require "rails_helper"
RSpec.describe LocalBackups::PartialCleanup do
  it "removes only abandoned partial directories" do
    Dir.mktmpdir do |directory|
      root = LocalBackups::StorageRoot.new(configured: directory, data_root: nil)
      old = root.path.join(".old.partial").tap(&:mkdir)
      fresh = root.path.join(".fresh.partial").tap(&:mkdir)
      sealed = root.path.join("sealed").tap(&:mkdir)
      File.utime(3.days.ago.to_time, 3.days.ago.to_time, old)
      expect(described_class.new(root:, older_than: 2.days.ago).call).to eq(1)
      expect(old).not_to exist
      expect(fresh).to exist
      expect(sealed).to exist
    end
  end
end

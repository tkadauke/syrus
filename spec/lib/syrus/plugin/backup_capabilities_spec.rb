require "rails_helper"

RSpec.describe "backup plugin capabilities" do
  [
    [Syrus::Plugin::BackupArtifactSource, %i[list describe open checksum pin release_pin record_replication]],
    [Syrus::Host::BackupDestination, %i[upload verify delete materialize_local health]]
  ].each do |contract, methods|
    it "defines and versions #{contract.name}" do
      provider = Class.new { include contract }
      methods.each { |method| provider.define_singleton_method(method) { |*| } }

      expect(provider).to be_compatible_version("1.0")
      expect(provider).not_to be_compatible_version("2.0")
      expect(methods - provider.methods).to be_empty
    end
  end
end

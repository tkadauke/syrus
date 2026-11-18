require "base64"

module PluginDesiredState
  class Publisher
    MANIFEST_KEY = "plugins/desired/manifest.json"
    SIGNATURE_KEY = "plugins/desired/manifest.json.sig"
    SCHEMA_VERSION = 1

    def self.publish!(...) = new(...).publish!

    def initialize(service: ActiveStorage::Blob.service, key: SigningKey.private_key)
      @service = service
      @key = key
    end

    def publish!
      ensure_artifacts_exist!
      PluginDesiredStateRevision.publish_next! do |revision|
        payload = manifest(revision)
        json = JSON.generate(payload)
        signature = Base64.strict_encode64(@key.sign(nil, json))

        @service.upload(SIGNATURE_KEY, StringIO.new(signature), checksum: nil, content_type: "application/octet-stream")
        @service.upload(MANIFEST_KEY, StringIO.new(json), checksum: nil, content_type: "application/json")
        payload
      end
    end

    private

    def desired_installations
      @desired_installations ||= PluginInstallation.where(enabled_for_sync: true).includes(:plugin_release).order(:plugin_name)
    end

    def ensure_artifacts_exist!
      desired_installations.each do |installation|
        release = installation.plugin_release
        next if release.source == "bundled"
        next if @service.exist?("#{ArtifactStore::PREFIX}#{release.content_digest}")

        raise MissingArtifact, "artifact is missing for #{release.name} #{release.version}"
      end
    end

    def manifest(revision)
      {
        schema_version: SCHEMA_VERSION,
        revision: revision,
        plugins: desired_installations.map do |installation|
          release = installation.plugin_release
          {
            name: release.name,
            version: release.version,
            digest: release.content_digest,
            size: release.size_bytes,
            roles: installation.roles,
            fleet_quarantined: installation.fleet_quarantined
          }
        end
      }
    end

    class MissingArtifact < StandardError; end
  end
end

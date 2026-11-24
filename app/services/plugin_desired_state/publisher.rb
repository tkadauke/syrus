require "base64"

class PluginDesiredState::Publisher
  SCHEMA_VERSION = 1
  MANIFEST_KEY = "plugins/desired/manifest.json".freeze
  SIGNATURE_KEY = "plugins/desired/manifest.json.sig".freeze

  def self.publish!(service: ActiveStorage::Blob.service)
    new(service:).publish!
  end

  def initialize(service:)
    @service = service
  end

  def publish!
    PluginDesiredState.transaction do
      state = PluginDesiredState.current
      state.lock!
      state.increment!(:revision)
      manifest = JSON.generate(manifest_for(state.revision))
      signature = Base64.strict_encode64(PluginDesiredState::SigningKey.current.sign(manifest))
      upload(SIGNATURE_KEY, signature, "application/octet-stream")
      upload(MANIFEST_KEY, manifest, "application/json")
      manifest
    end
  end

  private

  def manifest_for(revision)
    {
      schema_version: SCHEMA_VERSION,
      revision:,
      plugins: PluginInstallation.includes(:plugin_release).sync_managed.order(:plugin_name).map do |installation|
        release = installation.plugin_release
        {
          name: installation.plugin_name,
          version: release.version,
          digest: release.content_digest,
          size: release.size_bytes,
          roles: installation.roles,
          fleet_quarantined: installation.fleet_quarantined
        }
      end
    }
  end

  def upload(key, content, content_type)
    if @service.is_a?(ActiveStorage::Service::DiskService)
      temporary_key = "#{key}.tmp-#{SecureRandom.hex(8)}"
      @service.upload(temporary_key, StringIO.new(content), checksum: nil, content_type:)
      FileUtils.mkdir_p(File.dirname(@service.send(:path_for, key)))
      File.rename(@service.send(:path_for, temporary_key), @service.send(:path_for, key))
    else
      # S3-compatible PUT replaces an object atomically.
      @service.upload(key, StringIO.new(content), checksum: nil, content_type:)
    end
  end
end

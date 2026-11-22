require "digest"

class PluginInstaller
  Error = Class.new(StandardError)

  def initialize(actor:, trust_store: Syrus::PluginPackage::TrustStore.cached,
    registry_fetcher: PluginRegistryPackageFetcher.new(search: PluginRegistrySearch.new))
    @actor = actor
    @trust_store = trust_store
    @registry_fetcher = registry_fetcher
  end

  def stage_archive!(io, signature: nil, source: "upload", expected_name: nil, expected_version: nil,
    plugin_registry: nil, trust_store: @trust_store)
    bytes = io.read
    signature = signature.read if signature.respond_to?(:read)
    result = Syrus::PluginPackage::Validator.new(StringIO.new(bytes), signature: signature_io(signature),
      trust_store:, local: source != "registry").call
    raise Error, result.errors.join("; ") unless result.valid?
    raise Error, "registry package name does not match the requested plugin" if expected_name && result.manifest["name"] != expected_name
    raise Error, "registry package version does not match the requested plugin" if expected_version && result.manifest["version"] != expected_version

    verification = Syrus::PluginPackage::Verifier.new(package: StringIO.new(bytes), signature: signature_io(signature),
      trust_store:, local: source != "registry", name: result.manifest["name"], version: result.manifest["version"]).call
    raise Error, verification.errors.join("; ") unless verification.valid?

    manifest = result.manifest
    release = PluginRelease.find_or_initialize_by(name: manifest.fetch("name"), version: manifest.fetch("version"),
      content_digest: Digest::SHA256.hexdigest(bytes))
    release.assign_attributes(source:, trust_label: verification.trust_label, size_bytes: bytes.bytesize,
      uploaded_by: @actor, signature: signature, publisher_key_fingerprint: verification.fingerprint,
      plugin_registry: plugin_registry.is_a?(PluginRegistry) ? plugin_registry : nil)
    release.save!
    PluginArtifacts.store!(release, StringIO.new(bytes), trust_store:) unless release.archive.attached?
    stage!(release.name, PluginInstallation.exists?(plugin_name: release.name) ? "update" : "install", release, manifest.slice(
      "extension_points", "routes", "credential_types", "cli_commands", "roles", "public_host_apis"
    ))
  rescue Syrus::PluginPackage::Validator::Error, PluginArtifacts::TrustVerificationFailed, PluginArtifacts::DigestMismatch => error
    raise Error, error.message
  end

  def stage_release!(name, version: nil, digest: nil, source: nil, registry: nil)
    releases = PluginRelease.where(name:)
    releases = releases.where(content_digest: digest) if digest.present?
    releases = releases.where(source:) if source.present?
    release = version.present? ? releases.find_by(version:) : releases.to_a.max_by { |candidate| Gem::Version.new(candidate.version) }
    unless release
      arguments = { name:, version: }
      arguments[:registry] = registry if registry.present?
      package = @registry_fetcher.fetch(**arguments)
      @trust_store = package.trust_store || @trust_store
      return stage_archive!(package.archive, signature: package.signature, source: "registry",
        expected_name: package.name, expected_version: package.version, plugin_registry: package.registry,
        trust_store: @trust_store)
    end
    raise Error, "plugin release has been revoked" if trust_store_for(release).revoked?(release)

    manifest = capability_manifest(release)
    stage!(release.name, PluginInstallation.exists?(plugin_name: release.name) ? "update" : "install", release, manifest)
  rescue ArgumentError, PluginRegistryPackageFetcher::Error => error
    raise Error, error.message
  end

  def stage_remove!(name)
    raise ActiveRecord::RecordNotFound, name unless PluginInstallation.exists?(plugin_name: name)
    stage!(name, "remove", nil, {})
  end

  def confirm!(change)
    PluginChange.transaction do
      change.lock!
      raise Error, "plugin change has already been confirmed" unless change.status == "pending"
      if change.plugin_release && trust_store_for(change.plugin_release).revoked?(change.plugin_release)
        raise Error, "plugin release has been revoked"
      end

      installation = PluginInstallation.find_by(plugin_name: change.plugin_name)
      if change.remove?
        installation&.destroy!
      elsif installation
        installation.update!(plugin_release: change.plugin_release, desired_since: Time.current)
      else
        PluginInstallation.create!(plugin_name: change.plugin_name, plugin_release: change.plugin_release, roles: [])
      end
      change.update!(status: "confirmed", confirmed_by: @actor, confirmed_at: Time.current)
    end
    change
  end

  private

  def trust_store_for(release)
    return @trust_store unless release.plugin_registry
    PluginRegistryClient.new(source: release.plugin_registry).cached_trust_store
  end

  def capability_manifest(release)
    PluginChange.where(plugin_release: release, status: "confirmed").where.not(action: "remove").order(:confirmed_at).last&.capability_manifest || {}
  end

  def stage!(name, action, release, manifest)
    PluginChange.transaction do
      PluginChange.pending.where(plugin_name: name).update_all(status: "superseded", updated_at: Time.current)
      PluginChange.create!(plugin_name: name, action:, plugin_release: release, capability_manifest: manifest,
        status: "pending", staged_by: @actor)
    end
  end

  def signature_io(signature)
    StringIO.new(signature) if signature.present?
  end
end

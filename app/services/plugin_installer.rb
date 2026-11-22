require "digest"

class PluginInstaller
  Error = Class.new(StandardError)

  def initialize(actor:, trust_store: Syrus::PluginPackage::TrustStore.cached)
    @actor = actor
    @trust_store = trust_store
  end

  def stage_archive!(io, signature: nil, source: "upload")
    bytes = io.read
    result = Syrus::PluginPackage::Validator.new(StringIO.new(bytes), signature: signature_io(signature),
      trust_store: @trust_store, local: source != "registry").call
    raise Error, result.errors.join("; ") unless result.valid?

    manifest = result.manifest
    release = PluginRelease.find_or_initialize_by(name: manifest.fetch("name"), version: manifest.fetch("version"),
      content_digest: Digest::SHA256.hexdigest(bytes))
    release.assign_attributes(source:, trust_label: "unsigned_local", size_bytes: bytes.bytesize,
      uploaded_by: @actor, signature: signature)
    release.save!
    PluginArtifacts.store!(release, StringIO.new(bytes), trust_store: @trust_store) unless release.archive.attached?
    stage!(release.name, PluginInstallation.exists?(plugin_name: release.name) ? "update" : "install", release, manifest.slice(
      "extension_points", "routes", "credential_types", "cli_commands", "roles", "public_host_apis"
    ))
  rescue Syrus::PluginPackage::Validator::Error, PluginArtifacts::TrustVerificationFailed, PluginArtifacts::DigestMismatch => error
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

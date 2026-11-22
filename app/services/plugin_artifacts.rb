require "digest"

module PluginArtifacts
  DigestMismatch = Class.new(StandardError)
  TrustVerificationFailed = Class.new(StandardError)

  module_function

  def store!(release, io, trust_store: Syrus::PluginPackage::TrustStore.cached)
    raise ArgumentError, "bundled releases do not have an artifact" if release.source == "bundled"

    tempfile = Tempfile.new([ "plugin-release", ".archive" ], binmode: true)
    digest = Digest::SHA256.new
    size = 0
    while (chunk = io.read(64.kilobytes))
      tempfile.write(chunk)
      digest << chunk
      size += chunk.bytesize
    end
    tempfile.flush
    actual_digest = digest.hexdigest
    unless ActiveSupport::SecurityUtils.secure_compare(actual_digest, release.content_digest)
      raise DigestMismatch, "plugin artifact digest does not match the release"
    end
    raise DigestMismatch, "plugin artifact size does not match the release" unless size == release.size_bytes

    verify_trust!(release, tempfile, trust_store)

    tempfile.rewind
    blob = ActiveStorage::Blob.create_and_upload!(
      io: tempfile,
      key: key(actual_digest),
      filename: "#{release.name}-#{release.version}.archive",
      content_type: "application/octet-stream",
      metadata: { "sha256" => actual_digest },
      service_name: ActiveStorage::Blob.service.name
    )
    release.archive.attach(blob)
    release
  rescue ActiveRecord::RecordNotUnique
    blob = ActiveStorage::Blob.find_by!(key: key(release.content_digest))
    release.archive.attach(blob)
    release
  ensure
    tempfile&.close!
  end

  def key(digest)
    "plugins/artifacts/#{digest}"
  end

  def verify_trust!(release, package, trust_store)
    package.rewind
    signature = StringIO.new(release.signature) if release.signature.present?
    result = Syrus::PluginPackage::Verifier.new(
      package:, signature:, trust_store:, local: release.source != "registry",
      name: release.name, version: release.version
    ).call
    raise TrustVerificationFailed, result.errors.join(", ") unless result.valid?

    release.update!(trust_label: result.trust_label, publisher_key_fingerprint: result.fingerprint)
  ensure
    package.rewind
  end
end

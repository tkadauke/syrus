require "support/synthetic_runtime_image_provider"

# Publishes signed standard-base images through a synthetic provider so
# lifecycle specs can exercise BaseReleases without a registry or a build.
module CoworkerBaseReleaseHelpers
  def base_provider = (@base_provider ||= SyntheticRuntimeImageProvider.new)
  def base_service = (@base_service ||= RuntimeImages::Service.new(provider: base_provider))
  def base_releases = (@base_releases ||= RuntimeImages::BaseReleases.new(service: base_service))

  def base_namespace
    @base_namespace ||= RuntimeImageNamespace.find_or_create_by!(name: "syrus-base", owner_kind: "syrus_base", owner_ref: "coworker-base", provider_key: base_provider.key)
  end

  def publish_base(payload: SecureRandom.hex(8), platform: "linux/amd64", signed: true)
    source_digest = "sha256:#{Digest::SHA256.hexdigest("src-#{payload}")}"
    recipe_digest = "sha256:#{Digest::SHA256.hexdigest("recipe-#{payload}")}"
    provenance = { "recipe_digest" => recipe_digest }
    provenance[RuntimeImages::RuntimeAbi::ATTESTATION_KEY] = RuntimeImages::RuntimeAbi.attest(source_digest: source_digest, recipe_digest: recipe_digest) if signed
    base_service.publish(namespace: base_namespace, source_kind: RuntimeImages::CoworkerBase::SOURCE_KIND, source_ref: "coworker-base/generation-1",
                         source_digest: source_digest, platform: platform, provenance: provenance, payload: payload,
                         verification_state: "candidate")
  end

  def candidate(**args) = base_releases.register(publish_base(**args))

  def active_base(**args) = base_releases.promote!(candidate(**args), actor: "test")

  # An environment image built FROM +release+'s base, as the builder records it.
  def publish_environment(release, payload: SecureRandom.hex(8))
    base_service.publish(namespace: RuntimeImageNamespace.find_or_create_by!(name: "env", owner_kind: "coworker", owner_ref: "1", provider_key: base_provider.key),
                         source_kind: "coworker_environment", source_ref: "rev-#{payload}", platform: release.platform, payload: payload,
                         provenance: { "base_images" => [ { "reference" => "base@#{release.digest}", "pinned" => true, "digest" => release.digest } ] },
                         verification_state: "candidate")
  end
end

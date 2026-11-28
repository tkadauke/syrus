require "digest"
require "yaml"

# Authoritative lifecycle operation for a coworker-authored environment build.
# It snapshots the workspace, pins the active standard base and live policy,
# and binds the generic isolated-plane request to the immutable revision. It
# never publishes or activates the resulting image.
class Coworkers::EnvironmentBuildRequest
  Result = Data.define(:revision, :build_request) do
    def status
      request = build_request.reload
      { revision_id: revision.id, revision_number: revision.number, revision_state: revision.reload.state,
        build_request_id: request.id, build_state: request.state,
        image_digest: request.result&.digest, error_code: request.result&.error_code }
    end
  end

  def initialize(coworker, workspace, platform: "linux/amd64")
    @coworker = coworker
    @workspace = workspace
    @platform = platform
  end

  def call(created_by: nil, reason: nil)
    ensure_enabled!
    snapshot = Coworkers::EnvironmentSource.new(@coworker, @workspace).snapshot!(created_by: created_by)
    revision = snapshot.revision
    environment = revision.environment

    environment.with_lock do
      revision.reload(lock: true)
      return Result.new(revision:, build_request: revision.build_request) if revision.build_request

      manifest = revision.source_manifest.fetch("files")
      base = Syrus::Host::RuntimeImages.active_base(platform: @platform)
      raise BaseUnavailable, "no compatible active coworker base is available" unless base

      request = Syrus::Host::RuntimeImages.request_build(
        owner_kind: "coworker_environment", owner_ref: @coworker.id,
        source_kind: "coworker_environment", source_ref: "coworker-#{@coworker.id}/revision-#{revision.number}",
        files: manifest.to_h { |path, entry| [ path.delete_prefix("environment/"), entry.fetch("content") ] },
        recipe: { "dockerfile" => "Dockerfile", "context" => ".",
                  "build_args" => { Coworkers::EnvironmentSource::BASE_ARG => base.digest } },
        requester_kind: "coworker", requester_ref: @coworker.id, platform: @platform,
        policy_context: policy_context(manifest, base, created_by, reason)
      )

      revision.bind_build_inputs!(base_release_id: base.id, runtime_abi: base.runtime_abi,
                                  compat_min: base.compat_min, compat_max: base.compat_max,
                                  recipe_digest: request.recipe_digest)
      revision.transition_to!(:building, runtime_image_build_request_id: request.id)
      environment.transition_to!(:building) unless environment.building?
      Result.new(revision:, build_request: request)
    end
  end

  private

  def ensure_enabled!
    raise Disabled, "coworker custom environments are not enabled" unless Feature.coworker_custom_environments_enabled?
  end

  def policy_context(manifest, base, created_by, reason)
    environment_manifest = YAML.safe_load(manifest.fetch("environment/environment.yml").fetch("content"), aliases: false)
    { "coworker_id" => @coworker.id, "owner_user_id" => @coworker.owner_user_id,
      "source_digest" => manifest_digest(manifest), "base_digest" => base.digest,
      "runtime_abi" => base.runtime_abi, "network_classes" => Array(environment_manifest["network_classes"]).sort,
      "smoke_test" => environment_manifest.fetch("smoke_test"),
      "resources" => environment_manifest["resources"] || {}, "reason" => reason.presence || environment_manifest["reason"],
      "requested_by_user_id" => created_by&.id }
  end

  def manifest_digest(manifest)
    "sha256:#{Digest::SHA256.hexdigest(manifest.sort.map { |path, entry| "#{path}\0#{entry.fetch('sha256')}" }.join("\n"))}"
  end
end

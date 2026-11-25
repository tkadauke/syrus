require "digest"
require "rubygems/package"
require "stringio"

module RuntimeImages
  # Consumer-neutral entry point for submitting an in-memory, immutable source
  # tree to the isolated build plane. Consumers provide ownership and recipe
  # vocabulary; this service freezes the archive and the live build policy.
  class BuildRequests
    Base = Data.define(:id, :digest, :runtime_abi, :compat_min, :compat_max)

    def active_base(platform: BuiltImages::DEFAULT_PLATFORM)
      state = BaseReleases.new.launch_state(platform: platform)
      return unless state.ready?

      release = state.release

      Base.new(id: release.id, digest: release.digest, runtime_abi: release.runtime_abi,
               compat_min: release.compat_min, compat_max: release.compat_max)
    end

    def submit(owner_kind:, owner_ref:, source_kind:, source_ref:, files:, recipe:, requester_kind:, requester_ref:,
               platform: BuiltImages::DEFAULT_PLATFORM, policy_context: {})
      archive = source_archive(files)
      policy = BuildNetwork::Policy.current
      frozen_recipe = Hash(recipe).deep_stringify_keys.merge(
        "input_policy" => Hash(policy_context).deep_stringify_keys.merge(
          "build_network_policy_digest" => policy.digest,
          "build_network_policy_snapshot" => policy.snapshot,
          "confinement_policy_version" => RuntimeAbi::CONFINEMENT_POLICY_VERSION
        )
      )
      source = Builds::SourceCapture.capture(
        kind: source_kind, ref: source_ref, revision: "sha256:#{Digest::SHA256.hexdigest(archive)}",
        metadata: { "files" => files.keys.map(&:to_s).sort }
      )
      namespace = BuiltImages.new.namespace_for(owner_kind, owner_ref)
      request = Builds::Orchestrator.new.submit(
        namespace: namespace, source: source, recipe: frozen_recipe, platform: platform,
        requester_kind: requester_kind, requester_ref: requester_ref,
        source_archive: { io: StringIO.new(archive), filename: "source.tar", content_type: "application/x-tar" }
      )
      RuntimeImageBuildDispatchJob.perform_later
      request
    end

    private

    def source_archive(files)
      io = StringIO.new("".b)
      Gem::Package::TarWriter.new(io) do |tar|
        files.sort_by { |path, _| path.to_s }.each do |path, content|
          bytes = content.to_s.b
          mode = path.to_s.end_with?("smoke-test") ? 0o755 : 0o644
          tar.add_file_simple(path.to_s, mode, bytes.bytesize) { |entry| entry.write(bytes) }
        end
      end
      io.string
    end
  end
end

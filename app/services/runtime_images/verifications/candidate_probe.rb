module RuntimeImages
  module Verifications
    # Verifies a built extension image under the same immutable, non-root,
    # read-only envelope used by coworker turns. The probe receives no inherited
    # environment, secrets, registry credentials, or writable host mounts.
    class CandidateProbe
      OUTPUT_LIMIT = 64.kilobytes
      TIMEOUT = 120
      MEMORY_LIMIT = "1g"
      CPU_LIMIT = "1"

      def initialize(built_images: BuiltImages.new, runner: nil)
        @built_images = built_images
        @runner = runner || method(:run)
      end

      def call(image:, build_request_id:)
        request = RuntimeImageBuildRequest.find(build_request_id)
        policy = Hash(request.recipe.fetch("input_policy"))
        results = { "base_ancestry" => ancestry_result(image, policy) }
        return dependent_failures(results) unless results.fetch("base_ancestry").passed?

        @built_images.acquire(image) do |reference|
          metadata = inspect(reference)
          results["oci_metadata"] = metadata_result(image, metadata)
          results["runtime_abi"] = abi_result(image, metadata)
          results.merge!(conformance_results(reference))
          results["smoke_test"] = smoke_result(reference, policy.fetch("smoke_test"))
        end
        CandidateSuite.check_keys.to_h { |key| [ key, results.fetch(key) ] }
      rescue RuntimeImages::Error, Timeout::Error, SystemCallError => e
        unavailable(e)
      end

      private

      def ancestry_result(image, policy)
        expected = policy.fetch("base_digest")
        bases = Array(Hash(image.provenance)["base_images"])
        found = bases.any? { |base| base.is_a?(Hash) && base["digest"] == expected }
        return passed("base_ancestry", image.digest) if found

        Result.fail(failure_class: :integrity, code: :base_ancestry_mismatch,
                    message: "image does not descend from the pinned approved base")
      end

      def inspect(reference)
        output, status = @runner.call([ "docker", "image", "inspect", "--format", "{{json .}}", reference ])
        raise ProviderError, "image metadata inspection failed" unless status.to_i.zero?

        JSON.parse(output)
      rescue JSON::ParserError
        raise ProviderError, "image metadata is not valid JSON"
      end

      def metadata_result(image, metadata)
        platform = [ metadata["Os"], metadata["Architecture"] ].compact.join("/")
        user = metadata.dig("Config", "User").to_s.split(":", 2).first
        valid = platform == image.platform && CoworkerBase.platforms.include?(platform) &&
          user.present? && user != "0" && user != "root"
        return passed("oci_metadata", image.digest) if valid

        Result.fail(failure_class: :integrity, code: :oci_metadata_invalid,
                    message: "image platform or non-root user metadata is incompatible")
      end

      def abi_result(image, metadata)
        RuntimeAbi.validate_for_launch!(image: image, labels: metadata.dig("Config", "Labels") || {}, provider: nil)
        passed("runtime_abi", image.digest)
      rescue RuntimeAbi::Incompatible => e
        Result.fail(failure_class: :integrity, code: e.result.codes.first || :runtime_abi_incompatible, message: e.message)
      end

      def conformance_results(reference)
        output, status = @runner.call(constrained_command(reference))
        evaluated = ConformanceProbe.evaluate(output, exit_status: status, mode: ConformanceProbe::FULL_MODE)
        checks = evaluated.checks
        results = {}
        confinement_ok = ConformanceProbe::CONFINEMENT_CHECKS.all? { |key| checks[key] == :ok }
        results["confinement"] = confinement_ok ? passed("confined_probe", reference) :
          Result.fail(failure_class: :integrity, code: :confinement_failed, message: "image failed the confined runtime contract")
        RuntimeAbi.providers.each_key do |provider|
          keys = [ "provider-#{provider}", "abi-path-#{provider}" ]
          results["provider_#{provider}"] = keys.all? { |key| checks[key] == :ok } ? passed("provider_probe", provider) :
            Result.fail(failure_class: :integrity, code: :provider_probe_failed, message: "provider #{provider} probe failed")
        end
        results
      end

      def smoke_result(reference, command)
        argv = constrained_command(reference)
        image_index = command_image_index!(argv, reference)
        argv[option_value_index!(argv, "--entrypoint", before: image_index)] = "/bin/sh"
        argv.concat([ "-lc", command.to_s ])
        output, status = @runner.call(argv)
        return passed("smoke_test", Digest::SHA256.hexdigest(output.to_s)) if status.to_i.zero?

        Result.fail(failure_class: :policy, code: :smoke_test_failed, message: "candidate smoke test failed")
      end

      def run(argv)
        capture = ProcessRunner.new(env: ENV.slice("PATH", "HOME", "DOCKER_HOST", "XDG_RUNTIME_DIR").compact,
                                    command: argv, mounts: ProcessRunner.probe_mounts, network: "prepare", timeout: TIMEOUT,
                                    unsetenv_others: true).capture(limit: OUTPUT_LIMIT)
        result = capture.result
        [ capture.stdout.to_s + capture.stderr.to_s, result.timed_out? ? 124 : (result.success? ? 0 : 1) ]
      end

      def constrained_command(reference)
        argv = CoworkerBase.probe_command(reference)
        image_index = command_image_index!(argv, reference)
        position = option_value_index!(argv, "--pids-limit", before: image_index)
        argv.insert(position + 1, "--memory", MEMORY_LIMIT, "--cpus", CPU_LIMIT)
        argv
      end

      def command_image_index!(argv, reference)
        return argv.length - 1 if argv.last == reference && argv.count(reference) == 1

        raise ProviderError, "probe command must end with the candidate image reference"
      end

      def option_value_index!(argv, option, before:)
        position = argv.index(option)
        value_index = position && position + 1
        return value_index if value_index && value_index < before && !argv[value_index].to_s.start_with?("--")

        raise ProviderError, "probe command is missing a value for #{option}"
      end

      def dependent_failures(results)
        (CandidateSuite.check_keys - results.keys).each do |key|
          results[key] = Result.fail(failure_class: :integrity, code: :base_ancestry_unverified,
                                     message: "candidate execution skipped because base ancestry failed")
        end
        results
      end

      def passed(kind, digest)
        Result.pass(evidence_references: [ { "kind" => kind, "digest" => digest.to_s } ])
      end

      def unavailable(error)
        CandidateSuite.check_keys.to_h do |key|
          [ key, Result.fail(failure_class: :infrastructure, code: :candidate_probe_unavailable,
                             message: "candidate probe unavailable: #{error.class}") ]
        end
      end
    end
  end
end

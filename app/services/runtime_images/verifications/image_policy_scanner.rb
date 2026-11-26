require "tmpdir"

module RuntimeImages
  module Verifications
    # Inspects the immutable image and scans every build-controlled input that
    # can retain a credential: source, layers, history, metadata, and bounded
    # logs. The returned report is restricted evidence; callers expose counts
    # and policy codes, never finding values or snippets.
    class ImagePolicyScanner
      Report = Data.define(:metadata, :history, :secrets, :scanned_at)
      OUTPUT_LIMIT = 32.megabytes
      TIMEOUT = 10.minutes

      def initialize(built_images: BuiltImages.new, runner: nil)
        @built_images = built_images
        @runner = runner || method(:run)
      end

      def call(image:, request:, evidence:)
        @built_images.acquire_for_verification(image) do |reference|
          metadata = json([ "docker", "image", "inspect", reference ]).first || {}
          history = text([ "docker", "image", "history", "--no-trunc", "--format", "{{json .}}", reference ])
          secrets = json([ "trivy", "image", "--quiet", "--format", "json", "--scanners", "secret", reference ])
          Dir.mktmpdir("runtime-image-policy") do |dir|
            write_inputs(dir, request, evidence, history, metadata)
            auxiliary = json([ "trivy", "fs", "--quiet", "--format", "json", "--scanners", "secret", dir ])
            secrets = merge_results(secrets, auxiliary)
          end
          Report.new(metadata: metadata, history: history, secrets: secrets, scanned_at: Time.current)
        end
      end

      private

      def write_inputs(dir, request, evidence, history, metadata)
        File.binwrite(File.join(dir, "build.log"), evidence.log.finish.to_s)
        File.write(File.join(dir, "image-history.jsonl"), history)
        File.write(File.join(dir, "image-metadata.json"), JSON.generate(metadata))
        return unless request.source_archive.attached?

        archive = File.join(dir, "source.archive")
        File.binwrite(archive, request.source_archive.download)
        Builds::SourceExtractor.new.extract(archive, File.join(dir, "source"))
      end

      def merge_results(left, right)
        Hash(left).merge("Results" => Array(Hash(left)["Results"]) + Array(Hash(right)["Results"]))
      end

      def json(argv) = JSON.parse(text(argv))

      def text(argv)
        output, status, truncated = @runner.call(argv)
        raise ProviderError, "#{argv.first} policy inspection failed" unless status.to_i.zero?
        raise ProviderError, "#{argv.first} policy inspection output exceeded #{OUTPUT_LIMIT} bytes" if truncated
        output.to_s
      rescue JSON::ParserError
        raise ProviderError, "#{argv.first} policy inspection returned invalid JSON"
      end

      def run(argv)
        capture = ProcessRunner.new(env: ENV.slice("PATH", "HOME", "TRIVY_CACHE_DIR", "DOCKER_HOST", "XDG_RUNTIME_DIR").compact,
                                    command: argv, mounts: ProcessRunner.probe_mounts, network: "prepare",
                                    timeout: TIMEOUT, unsetenv_others: true).capture(limit: OUTPUT_LIMIT)
        result = capture.result
        [ capture.stdout.to_s, result.timed_out? ? 124 : (result.success? ? 0 : 1), capture.stdout_truncated ]
      end
    end
  end
end

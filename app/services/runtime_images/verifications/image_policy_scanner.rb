require "tmpdir"
require "fileutils"
require "rbconfig"

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
      SCAN_SCRIPT = Rails.root.join("bin/scan-runtime-image-inputs")
      NAMESPACE_PREFIX = %w[unshare --user --map-root-user --mount --].freeze
      MOUNT_SCRIPT = 'set -eu; mount -t tmpfs -o "size=$2,nr_inodes=$3,mode=0700" tmpfs "$1"; shift 3; exec "$@"'.freeze

      def initialize(built_images: BuiltImages.new, runner: nil)
        @built_images = built_images
        @runner = runner || method(:run)
      end

      def call(image:, request:, evidence:)
        @built_images.acquire_for_verification(image) do |reference|
          metadata = json([ "docker", "image", "inspect", reference ]).first || {}
          history = text([ "docker", "image", "history", "--no-trunc", "--format", "{{json .}}", reference ])
          secrets = json([ "trivy", "image", "--quiet", "--format", "json", "--scanners", "secret", reference ])
          Dir.mktmpdir("runtime-image-policy", ProcessRunner.probe_workdir.to_s) do |dir|
            write_inputs(dir, request, evidence, history, metadata)
            auxiliary = json(input_scan_command(dir, request.source_archive.attached?))
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
        stage_source(request.source_archive.attachment.blob, archive)
      end

      def stage_source(blob, archive)
        ceiling = Builds::Config.max_source_bytes
        if blob.byte_size > ceiling
          raise Builds::Rejected.new("source_too_large", "source archive is #{blob.byte_size} bytes, over the #{ceiling} byte limit")
        end

        written = 0
        File.open(archive, "wb") do |file|
          blob.download do |chunk|
            written += chunk.bytesize
            raise Builds::Rejected.new("source_too_large", "source archive exceeds the #{ceiling} byte limit") if written > ceiling

            file.write(chunk)
          end
        end
      end

      def input_scan_command(dir, archive_attached)
        work = File.join(dir, "work")
        FileUtils.mkdir_p(work)
        archive = archive_attached ? File.join(dir, "source.archive") : "-"
        [ *NAMESPACE_PREFIX, "sh", "-c", MOUNT_SCRIPT, "sh", work, scan_storage_bytes.to_s, scan_inodes.to_s,
          RbConfig.ruby, SCAN_SCRIPT.to_s, dir, work, archive, Builds::Config.max_source_bytes.to_s,
          Builds::Config.max_source_entries.to_s ]
      end

      def scan_storage_bytes = Builds::Config.max_source_bytes + (2 * OUTPUT_LIMIT) + Builds::Config.build_log_bytes
      def scan_inodes = Builds::Config.max_source_entries + 32

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

require "aws-sdk-s3"

module Admin
  module BuildCache
    # Talks to the shared sccache compiler-cache bucket (EPIC-251) directly
    # via the S3 API. Reuses the exact same env vars Steps::Prepare forwards
    # into prepare/grader subprocesses (Steps::Prepare::SCCACHE_ENV_FORWARD)
    # so there is one credential source for the whole cache feature, not a
    # second one introduced for this admin surface.
    class Client
      LIST_PAGE_SIZE = 1000
      # Safety cap on how many objects a single stats/clear pass will walk.
      # A compiler-cache bucket is bounded by nature (sccache expires its own
      # entries), but this keeps a misconfigured/shared bucket from turning
      # an admin page load or a full clear into an unbounded S3 scan.
      MAX_OBJECTS_SCANNED = 200_000

      Stats = Data.define(:object_count, :total_size_bytes, :oldest_object, :newest_object, :truncated)
      ObjectSummary = Data.define(:key, :size, :last_modified)
      ClearResult = Data.define(:deleted_count, :bytes_freed, :truncated)

      class << self
        def configured?
          ENV["SCCACHE_BUCKET"].present?
        end

        # Test seam: assign a callable to stand in for the real
        # Aws::S3::Client (e.g. `Aws::S3::Client.new(stub_responses: true)`)
        # so specs never reach real MinIO. Reset to nil in an `ensure`.
        attr_accessor :client_factory
      end

      def initialize
        @bucket = ENV["SCCACHE_BUCKET"].presence
        @key_prefix = ENV["SCCACHE_S3_KEY_PREFIX"].presence
      end

      def configured?
        @bucket.present?
      end

      # Aggregate footprint: object count, total size, oldest/newest object
      # age. Walks the whole bucket (bounded by MAX_OBJECTS_SCANNED) since
      # S3 doesn't expose a cheap way to get these aggregates directly.
      def stats
        count = 0
        total_size = 0
        oldest = nil
        newest = nil
        truncated = false

        each_object_batch do |batch|
          batch.each do |object|
            count += 1
            total_size += object.size.to_i
            oldest = object if oldest.nil? || object.last_modified < oldest.last_modified
            newest = object if newest.nil? || object.last_modified > newest.last_modified
          end
          if count >= MAX_OBJECTS_SCANNED
            truncated = true
            break
          end
        end

        Stats.new(object_count: count, total_size_bytes: total_size, oldest_object: oldest, newest_object: newest, truncated: truncated)
      end

      def clear_all!
        delete_matching { true }
      end

      def clear_older_than!(days)
        cutoff = days.to_i.days.ago
        delete_matching { |object| object.last_modified < cutoff }
      end

      private

      def delete_matching
        deleted_count = 0
        bytes_freed = 0
        truncated = false

        each_object_batch do |batch|
          matching = batch.select { |object| yield(object) }
          unless matching.empty?
            delete_objects(matching.map(&:key))
            deleted_count += matching.size
            bytes_freed += matching.sum { |object| object.size.to_i }
          end
          if deleted_count >= MAX_OBJECTS_SCANNED
            truncated = true
            break
          end
        end

        ClearResult.new(deleted_count: deleted_count, bytes_freed: bytes_freed, truncated: truncated)
      end

      def delete_objects(keys)
        keys.each_slice(1000) do |slice|
          client.delete_objects(
            bucket: @bucket,
            delete: { objects: slice.map { |key| { key: key } }, quiet: true }
          )
        end
      end

      def each_object_batch
        scanned = 0
        continuation_token = nil

        loop do
          response = client.list_objects_v2(
            bucket: @bucket,
            prefix: @key_prefix,
            max_keys: LIST_PAGE_SIZE,
            continuation_token: continuation_token
          )
          objects = Array(response.contents).map do |o|
            ObjectSummary.new(key: o.key, size: o.size, last_modified: o.last_modified)
          end
          yield objects unless objects.empty?

          scanned += objects.size
          break if scanned >= MAX_OBJECTS_SCANNED
          break unless response.is_truncated

          continuation_token = response.next_continuation_token
        end
      end

      def client
        @client ||= if self.class.client_factory
          self.class.client_factory.call
        else
          Aws::S3::Client.new(
            access_key_id: ENV["AWS_ACCESS_KEY_ID"],
            secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"],
            region: ENV["SCCACHE_REGION"].presence || "auto",
            endpoint: ENV["SCCACHE_ENDPOINT"],
            force_path_style: true
          )
        end
      end
    end
  end
end

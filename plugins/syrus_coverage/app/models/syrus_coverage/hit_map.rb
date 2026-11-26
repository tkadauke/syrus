require "zlib"

module SyrusCoverage
  # The per-line hit counts of one workflow's coverage run, gzipped into a blob
  # so the Source browser can show how often each line ran. Hit maps are large
  # and only useful while someone is reviewing the change, so they are purged
  # on a TTL and when the Job closes; the numbers worth keeping live on
  # SyrusCoverage::Snapshot.
  #
  # Structure: { "app/models/user.rb" => { "1" => 3, "2" => 0, "5" => 1 } }
  # (line number string => hit count; an absent line is not executable)
  class HitMap < Syrus::Host::Record
    self.table_name = "syrus_coverage_hit_maps"

    belongs_to :workflow, class_name: "::Workflow"
    has_one_attached :blob

    # Compressed blob created before this plugin owned storage: attached to the
    # Workflow itself under this name.
    LEGACY_ATTACHMENT_NAME = "coverage_hit_map".freeze

    class << self
      def store!(workflow, json_data)
        compressed = StringIO.new.tap do |io|
          gz = Zlib::GzipWriter.new(io)
          gz.write(JSON.generate(json_data))
          gz.close
        end.string

        record = find_or_create_by!(workflow_id: workflow.id)
        record.blob.attach(io: StringIO.new(compressed), filename: "coverage_hit_map.json.gz", content_type: "application/gzip")
        record
      end

      def for_workflow(workflow)
        find_by(workflow_id: workflow.id)
      end

      def attached_for?(workflow)
        for_workflow(workflow)&.blob&.attached? || legacy_attachment_for(workflow).present?
      end

      # Parsed hit map, or nil when none is attached. Reads a legacy
      # Workflow-attached blob too, until the TTL has expired it.
      def data_for(workflow)
        record = for_workflow(workflow)
        attachment = record&.blob&.attached? ? record.blob : legacy_attachment_for(workflow)&.blob
        return nil unless attachment

        JSON.parse(Zlib::GzipReader.new(StringIO.new(attachment.download)).read)
      end

      def purge_for!(workflow)
        for_workflow(workflow)&.destroy!
        legacy_attachment_for(workflow)&.purge
      end

      def legacy_attachment_for(workflow)
        ActiveStorage::Attachment.find_by(record_type: "Workflow", record_id: workflow.id, name: LEGACY_ATTACHMENT_NAME)
      end

      # Workflow ids whose hit map is older than the cutoff (current and legacy).
      def expired_workflow_ids(cutoff)
        current = joins(:workflow).where("syrus_coverage_hit_maps.created_at < ?", cutoff).pluck(:workflow_id)
        legacy = ActiveStorage::Attachment.where(record_type: "Workflow", name: LEGACY_ATTACHMENT_NAME)
                   .where("created_at < ?", cutoff).pluck(:record_id)
        (current + legacy).uniq
      end
    end
  end
end

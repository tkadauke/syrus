module OperatorBriefing
  module Detectors
    class Base
      class << self
        def fact(key:, severity:, summary:, evidence: [])
          OperatorBriefing::DetectorFact.new(
            key: "#{detector_key}:#{key}",
            severity: severity,
            summary: summary,
            evidence: evidence
          )
        end

        def evidence_for(files)
          Array(files).first(20).map { |file| { file: file } }
        end

        def detect(workflow:, diff:, changed_files:, name_status:, workspace_path:)
          []
        end

        private

        def files_matching(changed_files, patterns)
          changed_files.select do |file|
            patterns.any? { |pattern| pattern === file }
          end
        end

        def deleted_files(name_status)
          name_status.filter_map do |parts|
            status, file = parts
            file if status.to_s.start_with?("D")
          end
        end
      end
    end
  end
end

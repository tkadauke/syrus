require "digest"

module Runs
  # What makes two failed Runs "the same failure": the recorded problem code,
  # error class, and error message with volatile tokens (numbers, hex ids,
  # workspace paths) masked, so failures that differ only in a run id or a
  # timestamp count as one failure repeated.
  #
  # The classification is deliberately not part of it when an error was
  # recorded: the classifier can label the same error differently from run to
  # run (a native-gem build failure alternated between provider_transient and
  # timeout), and splitting on that would hide the repetition. Runs without a
  # recorded error fall back to their classification.
  #
  # Shared by the retry_storms invariant, which reports a repeated failure, and
  # Runs::RepeatedFailure, which stops retrying one.
  module FailureFingerprint
    MESSAGE_PREFIX = 300

    module_function

    def digest(classification:, error_class:, error_message:, problem_code:)
      if error_class.blank? && error_message.blank?
        return Digest::SHA256.hexdigest("classification\n#{classification}").first(16)
      end

      normalized = error_message.to_s
                                .gsub(%r{/[^\s:'"]*/(?:workflows|runs|tmp)/[^\s:'"]*}, "<path>")
                                .gsub(/\b[0-9a-f]{7,40}\b/i, "<hex>")
                                .gsub(/\d+/, "<n>")
                                .squish
                                .first(MESSAGE_PREFIX)
      Digest::SHA256.hexdigest([ problem_code, error_class, normalized ].join("\n")).first(16)
    end

    # run_id => fingerprint, for failed Runs, in two queries.
    def for_run_ids(run_ids)
      return {} if run_ids.empty?

      classifications = RunFailureClassification.where(run_id: run_ids).pluck(:run_id, :classification).to_h
      diagnostics = RunDiagnostic.where(run_id: run_ids).pluck(:run_id, :error_class, :error_message, :problem_code)
                                 .to_h { |id, *rest| [ id, rest ] }
      run_ids.index_with do |run_id|
        error_class, error_message, problem_code = diagnostics[run_id]
        digest(classification: classifications[run_id], error_class: error_class,
               error_message: error_message, problem_code: problem_code)
      end
    end
  end
end

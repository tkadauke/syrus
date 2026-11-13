module Admin
  # Raw JSONL transcript downloads for offline analysis (jq grep, etc.).
  # The navigable transcript UI is rendered by React from the app API.
  class TranscriptsController < BaseController
    include AdminTranscriptDelivery

    def download
      @run = Run.find(params[:run_id])
      session = ProviderSession.metadata_only.find_by(resumable: @run)

      unless session
        redirect_back fallback_location: job_path(@run.job),
                      alert: "No agent session captured for Run ##{@run.id}."
        return
      end

      stream_transcript(session, filename: "run-#{@run.id}-#{session.session_id}.jsonl")
    end
  end
end

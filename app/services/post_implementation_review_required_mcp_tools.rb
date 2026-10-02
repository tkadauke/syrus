class PostImplementationReviewRequiredMcpTools
  def self.call(job:, workflow:, run:)
    Syrus::PluginRegistry.providers_for(:post_implementation_review_provider).select do |provider|
      provider.review_needed?(job: job, trigger_kind: workflow&.trigger_kind || run&.trigger_kind)
    rescue StandardError
      false
    end.flat_map do |provider|
      Array(provider.required_mcp_tools(job: job, workflow: workflow, run: run))
    rescue StandardError
      []
    end.map(&:to_s).reject(&:blank?).uniq
  end
end

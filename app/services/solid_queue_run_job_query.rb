class SolidQueueRunJobQuery
  def self.matching(scope:, run_id:, limit: nil)
    new(scope: scope, run_id: run_id, limit: limit).matching
  end

  def initialize(scope:, run_id:, limit: nil)
    @scope = scope
    @run_id = run_id.to_i
    @limit = limit
  end

  def matching
    return scope.none unless run_id.positive?

    if mysql?
      scope.where(
        "(JSON_UNQUOTE(JSON_EXTRACT(arguments, '$.arguments[0]')) = ? OR " \
          "JSON_UNQUOTE(JSON_EXTRACT(arguments, '$.arguments[0]._aj_globalid')) = ?)",
        run_id.to_s,
        "gid://syrus/Run/#{run_id}"
      )
    else
      candidates = limit ? scope.limit(limit) : scope
      candidates.select { |job| argument_matches_run?(first_argument(job.arguments)) }
    end
  end

  private

  attr_reader :scope, :run_id, :limit

  def mysql?
    scope.connection.adapter_name.downcase.include?("mysql")
  end

  def first_argument(arguments)
    payload = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
    values = payload.is_a?(Hash) ? (payload["arguments"] || payload[:arguments]) : payload
    values.first if values.is_a?(Array)
  rescue JSON::ParserError, TypeError
    nil
  end

  def argument_matches_run?(argument)
    return argument == run_id || argument == run_id.to_s if argument.is_a?(Integer) || argument.is_a?(String)
    return false unless argument.is_a?(Hash)

    global_id = argument["_aj_globalid"] || argument[:_aj_globalid]
    global_id == "gid://syrus/Run/#{run_id}"
  end
end

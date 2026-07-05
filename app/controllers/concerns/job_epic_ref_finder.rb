module JobEpicRefFinder
  extend ActiveSupport::Concern

  private

  # Resolves a job identifier from a route param. Accepts numeric IDs
  # ("123"), the JOB-{n} prefix format ("JOB-123"), and human-readable
  # slugs ("my-feature-slug"). Raises ActiveRecord::RecordNotFound for
  # unknown slugs so the rescue_from handler returns a proper 404.
  def find_job_by_ref(scope, param)
    ref = param.to_s.strip
    ref = ref[4..] if ref.match?(/\Ajob-/i)
    if ref.match?(/\A\d+\z/)
      scope.find(ref.to_i)
    else
      scope.find_by(slug: ref) ||
        raise(ActiveRecord::RecordNotFound, "job #{ref.inspect} not found")
    end
  end

  # Resolves an epic identifier. Accepts numeric IDs, the EPIC-{n} prefix
  # format, and human-readable slugs.
  def find_epic_by_ref(scope, param)
    ref = param.to_s.strip
    ref = ref[5..] if ref.match?(/\Aepic-/i)
    if ref.match?(/\A\d+\z/)
      scope.find(ref.to_i)
    else
      scope.find_by(slug: ref) ||
        raise(ActiveRecord::RecordNotFound, "epic #{ref.inspect} not found")
    end
  end
end

# frozen_string_literal: true

module Deploy
  # Everything the phases for one cluster share. Passed rather than reached
  # for, so a phase can be constructed in a spec with a fake kubectl and a
  # fake clock and nothing else.
  ClusterContext = Struct.new(
    :label, :sha, :config, :kubectl, :flux_kubectl, :reporter, :waiter, :controls, :clock,
    keyword_init: true
  )
end

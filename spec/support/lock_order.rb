require "json"
require Rails.root.join("lib/syrus/lock_order")

# NY25: every spec runs under the row-lock order checker (Syrus::LockOrder).
# raise (the default) fails the example that takes locks out of order, except
# the inversions Syrus::LockOrder::PENDING_DECISION names; SYRUS_LOCK_ORDER=
# record collects every violation instead. Recorded ones are written to
# tmp/lock_order_violations.json at the end of the run.
Syrus::LockOrder::Checker.install!
# NY40 transition: the suite evaluates the hierarchical target order, with
# writes counted, and records what still breaks it instead of raising, while
# the transaction entry points are converted to Lineage.lock!. Once the
# recorded count reaches zero, this becomes raise again with the hierarchical
# order enforced. Specs that assert an order set LockOrder.target themselves.
Syrus::LockOrder.target = ENV.fetch("SYRUS_LOCK_ORDER_TARGET", "hierarchical").to_sym
ENV["SYRUS_LOCK_ORDER_WRITES"] ||= "1"
Syrus::LockOrder::Checker.mode = ENV.fetch("SYRUS_LOCK_ORDER", "record").to_sym

RSpec.configure do |config|
  config.after(:suite) do
    violations = Syrus::LockOrder::Checker.violations
    next if violations.empty?

    tally = violations.map { |violation| violation.to_h.transform_keys(&:to_s) }.tally
      .map { |violation, count| violation.merge("count" => count) }
      .sort_by { |violation| [ violation["held"], violation["taking"], violation["site"] ] }
    path = Rails.root.join("tmp", "lock_order_violations#{ENV['TEST_ENV_NUMBER']}.json")
    FileUtils.mkdir_p(path.dirname)
    File.write(path, JSON.pretty_generate(tally))
    warn "Row lock order: #{violations.size} violation(s) at #{tally.size} site(s); see #{path}"
  end
end

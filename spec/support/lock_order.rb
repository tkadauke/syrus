require "json"
require Rails.root.join("lib/syrus/lock_order")

# NY25: every spec runs under the row-lock order checker (Syrus::LockOrder).
# raise (the default) fails the example that takes locks out of order, except
# the inversions Syrus::LockOrder::PENDING_DECISION names; SYRUS_LOCK_ORDER=
# record collects every violation instead. Recorded ones are written to
# tmp/lock_order_violations.json at the end of the run.
Syrus::LockOrder::Checker.install!
# Writes count: an UPDATE or DELETE takes a row lock just as SELECT ... FOR
# UPDATE does (NY40).
ENV["SYRUS_LOCK_ORDER_WRITES"] ||= "1"
Syrus::LockOrder::Checker.mode = ENV.fetch("SYRUS_LOCK_ORDER", "raise").to_sym

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

require "rails_helper"

RSpec.describe "Prometheus alert rules" do
  it "ships canonical rules against exported Syrus metric names" do
    rules = YAML.load_file(Rails.root.join("config/prometheus/syrus-alert-rules.yml"))
      .fetch("groups")
      .flat_map { |group| group.fetch("rules") }

    expect(rules.map { |rule| rule.fetch("alert") }).to contain_exactly(
      "SyrusQueueOldestAgeHigh",
      "SyrusProviderCircuitOpen",
      "SyrusRecurringJobStale",
      "SyrusAttentionItemsGrowing"
    )

    expressions = rules.map { |rule| rule.fetch("expr") }.join("\n")
    expect(expressions).to include(
      "syrus_global_queue_oldest_age_seconds",
      "syrus_provider_circuit_state",
      "syrus_recurring_job_last_success_seconds",
      "syrus_attention_items_open_total"
    )
  end

  it "keeps recurring job staleness matchers aligned with config/recurring.yml" do
    recurring_jobs = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
      .fetch("default")
      .keys
      .to_set
    stale_rule = YAML.load_file(Rails.root.join("config/prometheus/syrus-alert-rules.yml"))
      .fetch("groups")
      .flat_map { |group| group.fetch("rules") }
      .find { |rule| rule.fetch("alert") == "SyrusRecurringJobStale" }
    matcher_jobs = stale_rule.fetch("expr").scan(/job(?:=|=~)"([^"]+)"/).flatten.flat_map { |value| value.split("|") }.to_set

    expect(matcher_jobs).to eq(recurring_jobs)
  end
end

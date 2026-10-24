require "rails_helper"
require "json"

RSpec.describe "Metrics Dashboard frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/metrics_dashboard/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "metrics_dashboard.json")))
  end

  it "uses Lauf terminology for Syrus executions in German" do
    expect(locale("de").fetch("panels")).to include(
      "queue_failed" => "Neue fehlgeschlagene Läufe, nach Job-Klasse",
      "queue_completed" => "Abgeschlossene Queue-Läufe",
      "runs_total" => "Läufe, nach Status",
      "active_agent_runs" => "Aktive Agentenläufe",
      "max_concurrent_agent_runs" => "Maximale gleichzeitige Agentenläufe"
    )
  end
end

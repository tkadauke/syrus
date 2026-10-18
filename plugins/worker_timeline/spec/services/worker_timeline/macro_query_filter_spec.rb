require "rails_helper"

RSpec.describe WorkerTimeline::MacroQueryFilter do
  # The subject is contributed by the plugin, so it exists only while the
  # plugin is enabled.
  before { PluginRecord.find_or_create_by!(name: "worker_timeline").update!(enabled: true, disableable: true) }

  def encode(tree) = Filters::QueryParam.encode(tree)

  describe ".schema" do
    it "describes repository_id/epic_id/hostname as fk fields, job_type/status as multi-select enums, and window as a date bucket" do
      fields = described_class.schema.index_by { |field| field.fetch("field") }

      expect(fields.keys).to contain_exactly("repository_id", "epic_id", "hostname", "job_type", "status", "window")
      expect(fields.fetch("repository_id")).to include("bucket" => "fk", "operators" => %w[ is ], "typeahead" => true)
      expect(fields.fetch("epic_id")).to include("bucket" => "fk", "operators" => %w[ is ], "typeahead" => true)
      expect(fields.fetch("hostname")).to include("bucket" => "fk", "operators" => %w[ is ], "typeahead" => true)
      expect(fields.fetch("job_type")).to include("bucket" => "enum", "operators" => %w[ is_one_of ])
      expect(fields.fetch("job_type").fetch("values")).to eq(
        [
          { "value" => "user", "label" => "User" },
          { "value" => "system", "label" => "Infrastructure" }
        ]
      )
      expect(fields.fetch("status")).to include("bucket" => "enum", "operators" => %w[ is_one_of ])
      expect(fields.fetch("status").fetch("values")).to eq(
        [
          { "value" => "queued", "label" => "Queued" },
          { "value" => "running", "label" => "Running" },
          { "value" => "succeeded", "label" => "Succeeded" },
          { "value" => "failed", "label" => "Failed" },
          { "value" => "cancelled", "label" => "Cancelled" }
        ]
      )
      expect(fields.fetch("window")).to include("bucket" => "date", "operators" => %w[ within_last between ])
    end
  end

  describe "#from / #to" do
    it "defaults to the last 3 hours with no window chip" do
      filter = described_class.new(nil)

      expect(filter.to - filter.from).to be_within(1).of(3.hours)
    end

    it "computes an absolute range from a within_last chip" do
      filter = described_class.new({ "and" => [ { "field" => "window", "op" => "within_last", "value" => { "n" => 30, "unit" => "minutes" } } ] })

      expect(filter.to - filter.from).to be_within(1).of(30.minutes)
    end

    it "computes an absolute range from a between chip" do
      filter = described_class.new({ "and" => [ { "field" => "window", "op" => "between", "value" => [ "2026-01-01", "2026-01-02" ] } ] })

      expect(filter.from).to eq(Time.zone.parse("2026-01-01"))
      expect(filter.to).to eq(Time.zone.parse("2026-01-02"))
    end

    it "rejects a within_last chip with an unsupported unit" do
      expect {
        described_class.new({ "and" => [ { "field" => "window", "op" => "within_last", "value" => { "n" => 30, "unit" => "fortnights" } } ] })
      }.to raise_error(ArgumentError, /invalid value/)
    end

    it "rejects a between chip with an unparsable bound" do
      expect {
        described_class.new({ "and" => [ { "field" => "window", "op" => "between", "value" => [ "not-a-date", "2026-01-02" ] } ] })
      }.to raise_error(ArgumentError, /invalid value/)
    end

    it "clamps a between chip's end bound to now when it names a future time" do
      future = 2.days.from_now
      filter = described_class.new({ "and" => [ { "field" => "window", "op" => "between", "value" => [ "2026-01-01", future.iso8601 ] } ] })

      expect(filter.to).to be_within(1).of(Time.current)
    end

    it "leaves a between chip's end bound alone when it is in the past" do
      filter = described_class.new({ "and" => [ { "field" => "window", "op" => "between", "value" => [ "2026-01-01", "2026-01-02" ] } ] })

      expect(filter.to).to eq(Time.zone.parse("2026-01-02"))
    end

    it "keeps the default display range for a negated window" do
      filter = described_class.new({ "not" => { "field" => "window", "op" => "within_last", "value" => { "n" => 30, "unit" => "minutes" } } })

      expect(filter.to - filter.from).to be_within(1).of(3.hours)
    end
  end

  describe "expression evaluation" do
    let(:job) { instance_double(Job, repository_id: 7, epic_id: 9, kind: "issue") }
    let(:workflow) { instance_double(Workflow, job:, state: "running", started_at: 20.minutes.ago, finished_at: nil, created_at: 30.minutes.ago) }

    it "evaluates every registered chip" do
      tree = {
        "and" => [
          { "field" => "repository_id", "op" => "is", "value" => 7 },
          { "field" => "epic_id", "op" => "is", "value" => 9 },
          { "field" => "hostname", "op" => "is", "value" => "worker-x" },
          { "field" => "status", "op" => "is_one_of", "value" => %w[ running queued ] },
          { "field" => "job_type", "op" => "is_one_of", "value" => %w[ user ] }
        ]
      }
      tree["and"] << { "field" => "window", "op" => "within_last", "value" => { "n" => 1, "unit" => "hours" } }
      filter = described_class.from_params(ActionController::Parameters.new(q: encode(tree)))

      expect(filter.matches_workflow?(workflow, source: :span, attribution: { hostname: "worker-x" })).to be(true)
    end

    it "composes nested AND, OR, and NOT groups" do
      tree = {
        "and" => [
          { "or" => [ { "field" => "repository_id", "op" => "is", "value" => 1 }, { "field" => "repository_id", "op" => "is", "value" => 7 } ] },
          { "not" => { "field" => "hostname", "op" => "is", "value" => "worker-y" } }
        ]
      }
      filter = described_class.new(tree)

      expect(filter.matches_workflow?(workflow, source: :span, attribution: { hostname: "worker-x" })).to be(true)
      expect(filter.matches_workflow?(workflow, source: :span, attribution: { hostname: "worker-y" })).to be(false)
    end

    it "evaluates pending workflows and idle instances with explicit source semantics" do
      status_filter = described_class.new({ "and" => [ { "field" => "status", "op" => "is_one_of", "value" => [ "running" ] } ] })
      hostname_filter = described_class.new({ "and" => [ { "field" => "hostname", "op" => "is", "value" => "worker-x" } ] })
      instance = instance_double(InstanceVersion, hostname: "worker-x", started_at: 1.hour.ago, finished_at: nil)

      expect(status_filter.matches_workflow?(workflow, source: :pending)).to be(true)
      expect(status_filter.matches_instance?(instance)).to be(false)
      expect(hostname_filter.matches_instance?(instance)).to be(true)
    end

    it "rejects unknown fields and unsupported operators" do
      expect { described_class.new({ "field" => "secret", "op" => "is", "value" => true }) }.to raise_error(Filters::UnknownFilterField)
      expect { described_class.new({ "field" => "hostname", "op" => "contains", "value" => "x" }) }.to raise_error(ArgumentError, /unsupported operator/)
    end
  end

  describe "#to_h" do
    it "round-trips the decoded q param's top-level chips" do
      tree = { "and" => [ { "field" => "hostname", "op" => "is", "value" => "worker-x" } ] }
      filter = described_class.from_params(ActionController::Parameters.new(q: encode(tree)))

      expect(filter.to_h).to eq(tree)
    end

    it "serializes to an empty AND when no q param is given" do
      filter = described_class.from_params(ActionController::Parameters.new)

      expect(filter.to_h).to eq({ "and" => [] })
    end
  end
end

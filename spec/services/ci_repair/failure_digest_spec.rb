require "rails_helper"

RSpec.describe CiRepair::FailureDigest do
  let(:job) { instance_double(Job, pr_number: 42, external_pr_number: nil) }

  def result(state:, failed_checks: [])
    CiRepair::CheckRefresh::Result.new(
      job: job,
      head_sha: "abc1234567890",
      state: state,
      detail: { failed_checks: failed_checks },
      refreshed_at: Time.current
    )
  end

  describe "pending checks" do
    it "reports that checks are still running, with no failure to diagnose" do
      digest = described_class.call(result(state: "pending"))

      expect(digest).to match(/still running/i)
      expect(digest).to match(/PR #42/)
      expect(digest).to match(/nothing to diagnose/i)
    end
  end

  describe "passing checks" do
    it "reports CI as currently green" do
      digest = described_class.call(result(state: "passing"))

      expect(digest).to match(/currently green/i)
      expect(digest).to match(/no failure to explain/i)
    end
  end

  describe "no check runs found" do
    it "reports there is nothing to explain" do
      digest = described_class.call(result(state: "unknown"))

      expect(digest).to match(/no check runs were found/i)
    end
  end

  describe "a known failing check" do
    let(:failed_checks) do
      [
        {
          name: "rspec",
          conclusion: "failure",
          summary: "3 examples, 1 failure",
          html_url: "https://github.com/acme/widgets/runs/1",
          log: <<~LOG
            Failures:

              1) Widget#price returns the price in cents
                 Failure/Error: expect(widget.price).to eq(100)

                   expected: 100
                        got: 0

            Finished in 1.2 seconds
            3 examples, 1 failure
          LOG
        }
      ]
    end

    it "names the failing check and includes structured error context extracted from the log" do
      digest = described_class.call(result(state: "failing", failed_checks: failed_checks))

      expect(digest).to match(/CI is failing for PR #42/)
      expect(digest).to include("## rspec — failure")
      expect(digest).to include("https://github.com/acme/widgets/runs/1")
      expect(digest).to include("3 examples, 1 failure")
      expect(digest).to include("\"parser\": \"rspec\"")
      expect(digest).to include("Widget#price returns the price in cents")
    end

    it "counts the total number of failing checks" do
      two_checks = failed_checks + [ failed_checks.first.merge(name: "lint") ]

      digest = described_class.call(result(state: "failing", failed_checks: two_checks))

      expect(digest).to match(/2 failing checks/)
      expect(digest).to include("## rspec — failure")
      expect(digest).to include("## lint — failure")
    end

    it "notes truncation when there are more failing checks than the shown maximum" do
      many_checks = Array.new(described_class::MAX_CHECKS + 2) { |i| failed_checks.first.merge(name: "check-#{i}") }

      digest = described_class.call(result(state: "failing", failed_checks: many_checks))

      expect(digest).to match(/#{many_checks.size} failing checks, showing #{described_class::MAX_CHECKS}/)
    end
  end

  describe "a failing check with no log, only a GitHub summary" do
    let(:failed_checks) do
      [ { name: "build", conclusion: "timed_out", summary: "The job timed out after 30 minutes", html_url: "https://github.com/acme/widgets/runs/2" } ]
    end

    it "parses the GitHub summary itself as the log when no check log is available" do
      digest = described_class.call(result(state: "failing", failed_checks: failed_checks))

      expect(digest).to include("## build — timed_out")
      expect(digest).to include("The job timed out after 30 minutes")
      expect(digest).to include("\"parser\": \"fallback\"")
    end
  end
end

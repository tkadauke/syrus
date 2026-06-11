require "rails_helper"

RSpec.describe SyrusCli::TestPlan do
  it "fetches the admin job payload and prints the newest completed test plan" do
    stdout = StringIO.new
    requested = []
    payload = {
      id: 456,
      issue_title: "Add user avatar upload",
      workflows: [
        {
          id: 1,
          state: "succeeded",
          finished_at: "2026-06-10T10:00:00Z",
          created_at: "2026-06-10T09:00:00Z",
          artifacts: {
            test_plan: {
              steps: [ "Old step" ],
              notes: "Old notes."
            }
          }
        },
        {
          id: 2,
          state: "running",
          finished_at: nil,
          created_at: "2026-06-11T09:00:00Z",
          artifacts: {
            test_plan: {
              steps: [ "Ignore running workflow" ],
              notes: nil
            }
          }
        },
        {
          id: 3,
          state: "succeeded",
          finished_at: "2026-06-11T10:00:00Z",
          created_at: "2026-06-11T09:00:00Z",
          artifacts: {
            test_plan: {
              steps: [
                "Navigate to /settings/profile",
                "Click \"Upload avatar\" and select a PNG under 2 MB",
                "Verify the avatar appears in the nav bar immediately"
              ],
              notes: "Avatar storage uses ActiveStorage."
            }
          }
        }
      ]
    }

    described_class.call(
      slug: "JOB-456",
      base_url: "https://syrus.example.com/",
      token: "syrus_secret",
      stdout: stdout,
      fetcher: lambda { |uri, token|
        requested << [ uri.to_s, token ]
        JSON.generate(payload)
      }
    )

    expect(requested).to eq([
      [ "https://syrus.example.com/api/v1/admin/jobs/456", "syrus_secret" ]
    ])
    expect(stdout.string).to eq(<<~TEXT)
      Test plan for JOB-456: Add user avatar upload

      1. Navigate to /settings/profile
      2. Click "Upload avatar" and select a PNG under 2 MB
      3. Verify the avatar appears in the nav bar immediately

      Notes: Avatar storage uses ActiveStorage.
    TEXT
  end

  it "prints the pending message when no completed workflow has a test plan" do
    stdout = StringIO.new
    payload = {
      id: 456,
      issue_title: "Add user avatar upload",
      workflows: [
        { id: 1, state: "running", artifacts: { test_plan: { steps: [ "Run smoke test" ] } } },
        { id: 2, state: "succeeded", artifacts: {} }
      ]
    }

    described_class.call(
      slug: "JOB-456",
      base_url: "syrus.example.com",
      token: "syrus_secret",
      stdout: stdout,
      fetcher: ->(_uri, _token) { JSON.generate(payload) }
    )

    expect(stdout.string).to eq(
      "No test plan available for JOB-456 yet — the job may still be implementing.\n"
    )
  end

  it "requires the documented job slug format" do
    expect {
      described_class.call(
        slug: "456",
        base_url: "https://syrus.example.com",
        token: "syrus_secret",
        fetcher: ->(_uri, _token) { "{}" }
      )
    }.to raise_error(ArgumentError, "job must use JOB-<id> format")
  end
end

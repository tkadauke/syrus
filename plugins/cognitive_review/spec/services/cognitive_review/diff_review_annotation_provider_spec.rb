require "rails_helper"

RSpec.describe CognitiveReview::DiffReviewAnnotationProvider do
  it "projects submitted workflow notes for the requested diff version into review annotations" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    note = CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 6,
      title: "Check lifecycle",
      explanation: "This range changes lifecycle behavior.",
      source_metadata: {}
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload.dig(:ranges, "app/models/job.rb")).to contain_exactly(
      hash_including(
        id: "cognitive_review_note:#{note.id}",
        component: "cognitive_review/note_marker",
        path: "app/models/job.rb",
        side: "new",
        start_line: 4,
        end_line: 6,
        title: "Check lifecycle",
        props: hash_including(
          note_id: note.id,
          job_id: job.id,
          path: "app/models/job.rb",
          explanation: "This range changes lifecycle behavior."
        )
      )
    )
    expect(payload[:panels]).to contain_exactly(
      hash_including(
        component: "cognitive_review/note_panel",
        props: hash_including(
          notes: [ hash_including(note_id: note.id) ],
          rollup: hash_including(
            total_flagged_ranges: 1,
            open_unhandled_count: 1,
            handled_count: 0,
            dismissed_count: 0,
            zero_note_state: false
          ),
          total: 1
        )
      )
    )
    expect(payload[:counts]).to contain_exactly(
      hash_including(id: "cognitive_review.total", value: 1),
      hash_including(id: "cognitive_review.open", value: 1, tone: "warning"),
      hash_including(id: "cognitive_review.handled", value: 0),
      hash_including(id: "cognitive_review.dismissed", value: 0)
    )
  end

  it "does not fall back to stale notes from an unrelated diff version" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    old_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "old-base",
      head_sha: "old-head",
      files: []
    )
    new_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: nil,
      base_sha: "new-base",
      head_sha: "new-head",
      files: []
    )
    CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: old_version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 4,
      title: "Old note",
      explanation: "This belongs to an older diff.",
      source_metadata: {}
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: new_version,
      base_sha: "new-base",
      head_sha: "new-head",
      files: []
    )

    expect(payload).to eq({})
  end

  it "counts acknowledged and discussed notes as handled rather than unresolved debt" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 4,
      end_line: 4,
      title: "Handled note",
      explanation: "Already handled.",
      state: "acknowledged",
      source_metadata: {}
    )
    discussed = CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 5,
      end_line: 5,
      title: "Discussed note",
      explanation: "Discussed already.",
      state: "discussed",
      source_metadata: {}
    )
    CognitiveReview::Note.create!(
      job: job,
      workflow: workflow,
      run: run,
      diff_review_version: version,
      path: "app/models/job.rb",
      side: "new",
      start_line: 6,
      end_line: 6,
      title: "Dismissed note",
      explanation: "Dismissed separately from handled.",
      state: "dismissed",
      source_metadata: {}
    )

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload[:ranges]).to eq({})
    expect(payload[:counts]).to contain_exactly(
      hash_including(id: "cognitive_review.total", value: 3),
      hash_including(id: "cognitive_review.open", value: 0, tone: "success"),
      hash_including(id: "cognitive_review.handled", value: 2),
      hash_including(id: "cognitive_review.dismissed", value: 1)
    )
    expect(payload.dig(:panels, 0, :props, :rollup)).to include(
      total_flagged_ranges: 3,
      open_unhandled_count: 0,
      acknowledged_count: 1,
      discussed_count: 1,
      dismissed_count: 1,
      handled_count: 2,
      zero_note_state: false
    )
    expect(discussed).to be_handled
  end

  it "surfaces a zero-note no-debt status for a reviewed diff version with no notes" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    CognitiveReview::Artifact.append!(run: run, notes: [], diff_review_version: version)

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload[:ranges]).to eq({})
    expect(payload[:counts]).to contain_exactly(
      hash_including(id: "cognitive_review.total", value: 0),
      hash_including(id: "cognitive_review.open", value: 0, tone: "success"),
      hash_including(id: "cognitive_review.handled", value: 0),
      hash_including(id: "cognitive_review.dismissed", value: 0)
    )
    expect(payload.dig(:panels, 0, :body)).to eq("No PR-level cognitive review debt was flagged for this diff version.")
    expect(payload.dig(:panels, 0, :props, :rollup)).to include(submitted: true, zero_note_state: true)
  end

  it "uses preloaded discussion entries when rendering note props" do
    job = Factories.job_with_run
    workflow = job.latest_workflow
    run = workflow.runs.first
    version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: []
    )
    user = Factories.user
    2.times do |index|
      note = CognitiveReview::Note.create!(
        job: job,
        workflow: workflow,
        run: run,
        diff_review_version: version,
        path: "app/models/job_#{index}.rb",
        side: "new",
        start_line: 4,
        end_line: 4,
        title: "Open note #{index}",
        explanation: "Still open, but with discussion history.",
        source_metadata: {}
      )
      CognitiveReview::DiscussionEntry.create!(note: note, user: user, body: "Earlier operator context #{index}")
    end

    discussion_selects = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      discussion_selects << sql if sql.match?(/\ASELECT\b/i) && sql.include?("cognitive_review_discussion_entries")
    end

    payload = described_class.review_annotations(
      job: job,
      user: job.user,
      version: version,
      base_sha: "base",
      head_sha: "head",
      files: []
    )

    expect(payload.dig(:panels, 0, :props, :notes).flat_map { |note| note[:discussion_entries] }.map { |entry| entry[:body] }).to contain_exactly(
      "Earlier operator context 0",
      "Earlier operator context 1"
    )
    expect(discussion_selects.size).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end
end

# Test Insights grader-name backfill

This one-off task copies each historical test run's grader name onto its test
cases. It advances by test-case primary key in bounded batches and records an
upper bound, so pausing, retrying, or rerunning it is safe. New ingestion fills
the column directly; summary reads keep using their compatibility query until
the relevant recent sample window has been populated.

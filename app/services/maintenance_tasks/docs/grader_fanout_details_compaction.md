# Compact Grader Fan-out Step Details

Type: one-off repair.

Grader fan-out steps used to store every grader target's full fingerprints
(worker environment, tool versions, input hashes) in the step's details, in
addition to the workflow artifacts that hold them. On a large repository one
such step could exceed MySQL's sort buffer, and pages or actions that sort a
workflow's steps then failed with "Out of sort memory" -- including restarting
a grade loop.

This task rewrites those steps' target selection and target-health entries
without the per-target fingerprints. The workflow artifacts are not
touched, so grading, landing validation and the target graph keep the full
data.

Why you might run it:

- A job page, bulk job action or grade-loop restart fails with "Out of sort
  memory".

Expected load: one small update per affected fan-out step, in batches of 100.

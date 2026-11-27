# Agent questions

Workflow agents can pause for a structured operator answer. Open questions are
shown by the question-mark count in the application sidebar. On mobile they
share the Activity inbox with notifications and approvals. Single choice,
multiple choice, free text, and a free-form response for choice questions all
use the same answer flow; submitting an answer resumes the paused workflow in
its existing agent session.

The Job page places a waiting question or agent blocker near the top. Answering
and continuing is the primary path. Operators can instead file a repair Job or
give up. Filing a repair creates a direct Job and adds it as a landed dependency,
so the blocked Job can resume after the repair lands. Giving up cancels the
attempt and closes the Job as cancelled. A secondary recovery option can cancel
the attempt, withdraw the unanswered question, and start a fresh implementation
attempt without added context; it requires confirmation because the agent may
ask the same question again. Technical blocker evidence stays behind a
disclosure.

Question eagerness resolves from the Job override, then repository setting,
then user setting, and finally the balanced default. Repository and user
settings may also define an answer timeout. Direct Job filing can select one of
the five eagerness levels for that Job.

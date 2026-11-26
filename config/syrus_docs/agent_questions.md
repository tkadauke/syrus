# Agent questions

Workflow agents can pause for a structured operator answer. Open questions are
shown by the question-mark count in the application sidebar. On mobile they
share the Activity inbox with notifications and approvals. Single choice,
multiple choice, free text, and a free-form response for choice questions all
use the same answer flow; submitting an answer resumes the paused workflow in
its existing agent session.

When a workflow agent asks a question, Syrus creates an
`agent_question_asked` notification for the Job owner. Selecting the
notification opens the waiting question on the Job page. Operators can enable
or disable this notification kind in their notification preferences.

The Jobs list and Dashboard include a **Waiting for your answer** smart folder.
It selects Jobs owned by the current operator that have an open workflow-agent
question. The same condition is available in the shared filter bar as the
**Waiting for your answer** boolean filter, so it can be combined with other
Job filters and saved in custom smart folders.

The Job page places a waiting question or agent blocker near the top. Operators
can answer and continue, retry without changing the blocker, file a repair Job,
or give up. Filing a repair creates a direct Job and adds it as a landed
dependency, so the blocked Job can resume after the repair lands. Giving up
cancels the attempt and closes the Job as cancelled. Technical blocker evidence
stays behind a disclosure.

Question eagerness resolves from the Job override, then repository setting,
then user setting, and finally the balanced default. Repository and user
settings may also define an answer timeout. Direct Job filing can select one of
the five eagerness levels for that Job.

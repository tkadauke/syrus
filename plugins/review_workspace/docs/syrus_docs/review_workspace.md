# Review workspace

The Review workspace is a focused list of Jobs on which the signed-in operator can make an approval decision now. Enable the bundled **Review Workspace** plugin to add **Review** to the primary sidebar. Its badge is the number of currently actionable Jobs.

A Job appears only when it is visible and writable by the operator, is an ordinary non-investigation Job in the implemented state, can accept that operator's approval, and has no approval-blocking runtime work. Jobs with unresolved dependencies remain reviewable but sort after otherwise equivalent unblocked Jobs. Explicit priority, the time the Job became ready, and its numeric ID complete the deterministic ordering.

Selecting **Review** opens a full-screen, distraction-free workspace with the eligible Job rail, the canonical Job review evidence and source-diff experience, and approval and feedback actions. Visual evidence, diff versions, annotations, and plugin-contributed review content are the same content shown on Job detail. Jobs without screenshots show the canonical no-evidence state instead of a placeholder artifact.

The workspace stores no inbox, read/unread, or durable deferred state. Defer only removes a Job for the current workspace session. A deep link selects a Job only while it remains eligible; otherwise the workspace safely selects the first current item or shows its caught-up state. Approval and feedback use the normal Job lifecycle endpoints and recheck authorization and the current PR state. Successful actions remove the item and advance the stack.

Keyboard controls mirror visible controls: J/K selects Jobs, left/right navigates visual evidence, A starts approval, F opens feedback, and Escape exits. Exiting returns to the previous application view.

Disabling the plugin removes its routes, sidebar entry, badge, and frontend contribution without changing Jobs or approval records.

# Review workspace

The Review workspace is a focused list of Jobs on which the signed-in operator can make an approval decision now. Enable the bundled **Review Workspace** plugin to add **Review** to the primary sidebar. Its badge is the number of currently actionable Jobs.

A Job appears only when it is visible and writable by the operator, is an ordinary non-investigation Job in the implemented state, can accept that operator's approval, and has no approval-blocking runtime work. Jobs with unresolved dependencies remain reviewable but sort after otherwise equivalent unblocked Jobs. Explicit priority, the time the Job became ready, and its numeric ID complete the deterministic ordering.

The workspace stores no inbox, read/unread, or deferred state. A deep link selects a Job only while it remains eligible; otherwise the workspace safely selects the first current item or shows its caught-up state. Opening or acting on a Job uses the normal Job review and lifecycle authorization checks again.

Disabling the plugin removes its routes, sidebar entry, badge, and frontend contribution without changing Jobs or approval records.

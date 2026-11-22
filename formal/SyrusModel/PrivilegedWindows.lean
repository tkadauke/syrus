/-!
# DOC-44 desktop: untrusted content never reaches the privileged bridge

"Only the configured server origin remains in the privileged web container",
"non-HTTP protocols are denied", and "untrusted renderer content cannot invoke
filesystem, credential, backend-control, or process IPC".

The desktop has two kinds of window:

- the *web-app* window (`webAppWindow.ts`). It shows the remote Syrus app,
  sandboxed, with a narrow bridge. Every handler on that bridge re-validates
  the sender with `shellSenderAllowed`: the web-app window, its top frame, and
  the instance origin.
- *privileged* windows: the tray popover, Preferences and onboarding. They
  show the bundled renderer with `preload.cjs`, whose handlers (credentials,
  checkout, installer) do not check the sender.

Content starts navigations by clicking a link, dropping a link or file, being
redirected, or calling `window.open`. Before F82, privileged windows had no
guard, so a dropped link or HTML file loaded foreign content with
`preload.cjs` attached.

`decideWindowOpen` keeps the web-app window on the server origin: it loads
same-origin http(s) targets in the window, hands other http(s) targets to the
browser, and denies anything else. Privileged windows now refuse every
content-started navigation and popup.

Over every sequence of up to four content-started navigations to the local
renderer, the server, a foreign http(s) origin, or a `file:` URL:

- a privileged window only ever shows the local renderer, so the privileged
  bridge is only reachable by bundled content (`privileged_bridge_local_only`);
- the web-app window only ever shows the server origin (`web_app_on_server`);
- before the guard, a privileged window could show foreign content
  (`before_violates`).
-/

namespace SyrusModel
namespace PrivilegedWindows

inductive Origin where
  | localRenderer
  | server
  | foreign
  | file
deriving DecidableEq, Repr

inductive Window where
  | webApp
  | privileged
deriving DecidableEq, Repr

inductive Action where
  | main
  | external
  | deny
deriving DecidableEq, Repr

/-- `decideWindowOpen` over the origin classes (the server origin is the
configured one; `file:` and other non-http(s) protocols are denied). -/
def decideWindowOpen : Origin → Action
  | .server => .main
  | .foreign => .external
  | .file | .localRenderer => .deny

/-- What a window shows after a content-started navigation. -/
def navigate (guarded : Bool) : Window → Origin → Origin → Origin
  | .webApp, current, target => if decideWindowOpen target == .main then target else current
  | .privileged, current, target => if guarded then current else target

def start : Window → Origin
  | .webApp => .server
  | .privileged => .localRenderer

def shows (guarded : Bool) (w : Window) (targets : List Origin) : List Origin :=
  targets.scanl (navigate guarded w) (start w)

def origins : List Origin := [.localRenderer, .server, .foreign, .file]

def sequences : Nat → List (List Origin)
  | 0 => [[]]
  | k + 1 => [] :: (sequences k).flatMap (fun rest => origins.map (· :: rest))

def check : Bool :=
  (sequences 4).all (fun ts =>
    (shows true .privileged ts).all (· == .localRenderer) &&
    (shows true .webApp ts).all (· == .server))

theorem privileged_bridge_local_only_and_web_app_on_server : check = true := by native_decide

theorem before_violates : (shows false .privileged [.file]).contains .file = true := by native_decide

end PrivilegedWindows
end SyrusModel

/-!
# DOC-44 desktop: stable and test installations are isolated

"Stable and test project names, ports, containers, images, and volumes are
disjoint", "Destructive reset is impossible outside the test channel", and
"Every destructive target derives from a validated channel-specific manifest,
not a broad path or unresolved variable."

The desktop app (`stackIdentity` in `desktop/electron/channel.ts`) and
`uninstall.sh` each derive every resource from one fixed per-channel table.
This model is that table, and the targets of every destructive operation:

- `wipe` ("Reset Test Setup…", `wipeBackendStack`): refused unless the channel
  is test.
- `uninstall` with or without `--keep-data`.

Docker resources are scoped by the Compose project. `compose -p <project>`
takes precedence over the compose file's top-level `name: syrus`, and no
volume declares a fixed `name:`. Plugin-runtime resources are selected by the
`dev.syrus.runtime.project=<project>` label. Images are scoped by tag channel.
Both callers now apply the same rule: test means `test-<x>`, or a tag ending
in `-test.<digits>` (F79). The resources shared by both channels are `~/.syrus`
itself, which is only ever `rmdir`'d when empty, and the stable-only Claude
skill, which a test uninstall skips.

Proved:

- the two channels' resource sets are disjoint (`channels_disjoint`);
- every destructive target of a channel lies in that channel's own set
  (`targets_in_own_channel`);
- `wipe` on stable removes nothing (`no_stable_wipe`);
- `--keep-data` removes no data resource (`keep_data_keeps_data`).
-/

namespace SyrusModel
namespace ChannelIsolation

inductive Channel where
  | stable
  | test
deriving DecidableEq, Repr

inductive Resource where
  | project (name : String)
  | stateDir (path : String)
  | credentials (path : String)
  | volume (name : String)
  | runtimeLabel (project : String)
  | imageTags (channel : Channel)
  | cli (path : String)
  | appBundle (name : String)
  | settings (name : String)
  | skill (path : String)
deriving DecidableEq, Repr

def project : Channel → String
  | .stable => "syrus"
  | .test => "syrus-test"

def isData : Resource → Bool
  | .stateDir _ | .credentials _ | .volume _ | .settings _ => true
  | _ => false

/-- `stackIdentity` and uninstall.sh's channel table. -/
def resources (c : Channel) : List Resource :=
  let p := project c
  let test := c == .test
  [ .project p,
    .stateDir (if test then "~/.syrus/local-test" else "~/.syrus/local"),
    .credentials (if test then "~/.syrus/credentials.test" else "~/.syrus/credentials"),
    .volume (p ++ "_syrus-data"), .volume (p ++ "_syrus-search"),
    .volume (p ++ "_syrus-mise-cache"), .volume (p ++ "_syrus-plugins"),
    .runtimeLabel p, .imageTags c,
    .cli (if test then "~/.local/bin/syrus-test" else "~/.local/bin/syrus"),
    .appBundle (if test then "Syrus Test.app" else "Syrus.app"),
    .settings (if test then "Syrus Test" else "Syrus") ] ++
  (if test then [] else [.skill "~/.claude/skills/syrus"])

inductive Op where
  | wipe
  | uninstall (keepData : Bool)
deriving DecidableEq, Repr

/-- What each operation removes, as the code derives it. -/
def targets : Channel → Op → List Resource
  | .stable, .wipe => []
  | c, .wipe =>
    let p := project c
    [ .project p, .volume (p ++ "_syrus-data"), .volume (p ++ "_syrus-search"),
      .volume (p ++ "_syrus-mise-cache"), .volume (p ++ "_syrus-plugins"), .runtimeLabel p ]
  | c, .uninstall keepData =>
    (resources c).filter (fun r => !(keepData && isData r))

def channels : List Channel := [.stable, .test]
def ops : List Op := [.wipe, .uninstall true, .uninstall false]

def check : Bool :=
  (resources .stable).all (fun r => !(resources .test).contains r) &&
  channels.all (fun c => ops.all (fun o => (targets c o).all (fun r => (resources c).contains r))) &&
  (targets .stable .wipe).isEmpty &&
  channels.all (fun c => (targets c (.uninstall true)).all (fun r => !isData r))

theorem channels_disjoint_and_targets_in_own_channel : check = true := by native_decide

end ChannelIsolation
end SyrusModel

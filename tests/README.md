# tests/ — GDScript unit tests (S-T-1)

Headless unit tests for the shared pure functions and the server-side boundary
rules, run through Godot's `--script` mode (`extends SceneTree`). No addon and no
test framework: the runner is ~100 lines and exits non-zero on the first failing
suite.

The whole suite is also wired into `scripts/ci.ps1` and the GitHub Actions
workflow, so a normal CI run exercises it before the bot.

## Run

```powershell
$env:GODOT = "D:\code\game\godot_engine\Godot_v4.7.1-stable_win64_console.exe"

# Unit tests only (needs a prior --import of the server project). The runner is
# loaded by an absolute path because tests/ lives at the repo root, outside the
# server project; a relative `--script tests/run_tests.gd` would resolve to the
# non-existent `res://tests/...` and fail.
& $env:GODOT --headless --path server --script "<repo-root>\tests\run_tests.gd"

# Everything (contract verify -> parse -> unit tests -> bot -> export):
powershell -File scripts/ci.ps1
```

The suite runs under the **server** project because it also covers
`CombatService`, and the server project registers every shared `class_name` too.
`run_tests.gd` is loaded by absolute path, which is why the directory can live at
the repo root next to `shared/`.

## Adding a case

Drop a new `*_test.gd` file in this directory; the runner globs it automatically
and never has to be edited (the same "add a file, not an edit" rule as the bot
check registry). A module is a plain script:

```gdscript
extends RefCounted

func cases() -> Array[Dictionary]:
    var out: Array[Dictionary] = []
    out.append({"name": "my_boundary", "ok": Movement.clamp_bounds(...).x == 0.0, "detail": ""})
    return out
```

Each result is `{"name": String, "ok": bool, "detail": String}`. A workbench that
adds shared behaviour (WB2 formulas, WB6 prediction, …) should add its own
`<domain>_test.gd` here.

## Current coverage

- `movement_test.gd` — map bounds clamp (both axes, inclusive edge, y untouched),
  AABB obstacle push-out (all four faces + no-op + y untouched), non-finite input
  rejection (`is_input_finite` and the `WorldState.set_input` production guard),
  deterministic `step()` distance/floor behaviour.
- `formulas_test.gd` — `Formulas.melee_damage` boundaries (armor reduction and
  the never-below-1 floor).
- `combat_boundaries_test.gd` — `CombatService._reject_reason` range boundary
  (`distance == MELEE_RANGE` is allowed, strictly over is rejected), cooldown
  boundary (`> 0` rejects, `0` allows) and invalid attacker/target cases.

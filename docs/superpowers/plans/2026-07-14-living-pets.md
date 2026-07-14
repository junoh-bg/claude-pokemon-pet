# Living Pets — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Procedural character motion (breathe/waddle/lunge/recoil) + element-colored attack projectiles on every caption rotation, per the approved spec (`docs/superpowers/specs/2026-07-14-living-pets-design.md`).

**Architecture:** Core computes `element` into `resolved.json` (pokemon → type; digimon → keyword inference on the EN attack). Overlay animates the existing `imageView` layer via CA transform sub-paths (rotation and translation compose with an always-on scale.y breathe loop) and manages projectile layer lifecycles from the existing 20 fps `move()` tick — no new timers. Terminal fakes poses with row/column offsets and renders a projectile line between sprite and HUD.

**Tech Stack:** jq (core), JXA/QuartzCore (overlay), Python stdlib (terminal).

## Global Constraints

- All prior invariants; every overlay animation call guarded try/catch (failure = still pet, never broken pet).
- **JXA bridging rules (learned Phase 4, MUST follow):** never pass a JS array via `$([...])` to an ObjC API expecting NSArray (bridges as NSNull members) — build `$.NSMutableArray.array` + `addObject`; never pass raw CGImageRef; niladic selectors are property access (no parens); numbers into `id` slots go through `$.NSNumber.numberWithDouble`.
- Attack cadence: the existing caption-slot clock (`Math.floor(Date.now()/7000)` change while `working`) — visual and caption always match.
- Element keyword order matters: test `heaven|holy` before `dark` etc. exactly as specified; inference reads the pack's EN attack (never the localized caption).
- Version 0.10.0.

## File Structure

| File | Change |
|---|---|
| `scripts/pet-core.sh` | `element` in RESOLVE_JQ |
| `scripts/pet-overlay.js` | pose engine, projectile system, element colors (holy/dark), triggers |
| `scripts/pet-term.py` | breathe/lunge offsets, recoil flash, projectile line, element colors |
| `tests/test-resolve.sh`, `tests/test-digimon.sh` | element assertions |
| `tests/test_term.py` | projectile/breathe/element unit tests |
| `README.md`, `CLAUDE.md`, `.claude-plugin/plugin.json` | docs + 0.10.0 |

---

### Task 1: Core — `element` (TDD)

- [ ] **Step 1: Failing tests.** `tests/test-resolve.sh` (pokemon: element == type):

```bash
setup  # element mirrors the type for pokemon
charmander_partner; set_tasks 0; "$CORE" resolve
assert_eq "pokemon element = type" "fire" "$(R .element)"
teardown
```

`tests/test-digimon.sh` (keyword classes; species pinned via direct partner lines):

```bash
setup  # element inference from the EN attack, independent of display language
elem_of() {  # <species...> — partner whose current species is the last arg
    printf '{"franchise":"digimon","line":[%s],"type":"vpet","date":"2026-07-13","seed":0}' \
        "$(printf '"%s",' "$@" | sed 's/,$//')" > "$CACHE/partner"
    set_tasks 18; "$CORE" resolve; R .element
}
assert_eq "baby flame → fire"      "fire"     "$(elem_of botamon koromon agumon greymon metalgreymon_virus | tail -1)"
assert_eq "ice arrow → ice"        "ice"      "$(elem_of poyomon tokomon patamon unimon andromon seadramon | tail -1)"
teardown
```

(Write it simpler and explicit — the helper above is illustrative; in the real test use five standalone blocks, each writing a partner JSON whose LAST line member is the species under test with `set_tasks 18`, asserting: agumon-line ultimate `metalgreymon_virus`→fire (Giga Destroyer has no keyword → wait, "Destroyer" matches nothing → vpet!). **Pin exact expectations from the shipped attack names:**
  - `agumon` (Baby Flame) → fire — partner `["botamon","koromon","agumon"]`, tasks 5
  - `seadramon` (Ice Arrow) → ice — `["botamon","koromon","betamon","seadramon"]`, tasks 10
  - `betamon` (Electric Shock) → electric — `["botamon","koromon","betamon"]`, tasks 5
  - `angemon` (Heaven's Knuckle) → holy — `["punimon","tunomon","gabumon","angemon"]`, tasks 10
  - `devimon` (Death Claw) → dark — `["botamon","koromon","agumon","devimon"]`, tasks 10
  - `numemon` (Poop Throw) → poison — `["botamon","koromon","agumon","numemon"]`, tasks 10
  - `koromon` (Bubbles) → vpet — `["botamon","koromon"]`, tasks 2
  - ko-mode: `echo ko > lang`, agumon partner → element still "fire".)

- [ ] **Step 2: red.**
- [ ] **Step 3: RESOLVE_JQ** — after the `$mv` binding add:

```jq
  (if $mb == "species"
   then (($spec.attack.en // "") | ascii_downcase) as $atk
      | (if   ($atk | test("flame|fire|burning|heat")) then "fire"
         elif ($atk | test("ice|snow|zero"))           then "ice"
         elif ($atk | test("thunder|electric|shock|spark")) then "electric"
         elif ($atk | test("water|hydro|tidal|wave"))  then "water"
         elif ($atk | test("poison|sludge|acid|poop")) then "poison"
         elif ($atk | test("heaven|holy"))             then "holy"
         elif ($atk | test("death|devil|hell|dark|oblivion")) then "dark"
         else "vpet" end)
   else $p.type end) as $element |
```

and `element: $element,` in the output object (after `type`).
- [ ] **Step 4: green; commit** `feat: element field — type for pokemon, attack-keyword inference for digimon`.

---

### Task 2: Overlay — pose engine + projectiles

All in `scripts/pet-overlay.js`; every block guarded. Manual smoke after.

- [ ] **Step 1: Layer prep + breathe** (after `imageView` setup):

```javascript
  // pose engine: anchor at the feet so scaling/tilting looks like a body
  try {
    var ivf = imageView.frame;
    imageView.layer.setAnchorPoint($.CGPointMake(0.5, 0));
    imageView.layer.setPosition($.CGPointMake(ivf.origin.x + ivf.size.width / 2, ivf.origin.y));
    var breathe = $.CABasicAnimation.animationWithKeyPath($('transform.scale.y'));
    breathe.setFromValue($.NSNumber.numberWithDouble(1.0));
    breathe.setToValue($.NSNumber.numberWithDouble(1.03));
    breathe.setDuration(1.5);
    breathe.setAutoreverses(true);
    breathe.setRepeatCount(999999);
    imageView.layer.addAnimationForKey(breathe, $('breathe'));
  } catch (e) {}
```

- [ ] **Step 2: Element colors + attack primitives.** Extend `TYPE_RGB` with `holy: [1, .85, .4], dark: [.55, .35, .75]`. `setupEmitter`/`fxColor` key on `p.element` (falls back to type — same table). Add:

```javascript
  var projectiles = [];   // {layer, until, ix, iy}
  function lunge(dir) {
    try {
      var a = $.CAKeyframeAnimation.animationWithKeyPath($('transform.translation.x'));
      var vals = $.NSMutableArray.array;   // NEVER $([...]) — bridges as NSNull
      vals.addObject($.NSNumber.numberWithDouble(0));
      vals.addObject($.NSNumber.numberWithDouble(dir * 14));
      vals.addObject($.NSNumber.numberWithDouble(0));
      a.setValues(vals);
      a.setDuration(0.25);
      imageView.layer.addAnimationForKey(a, $('lunge'));
    } catch (e) {}
  }
  function fireProjectile(dir, rgb) {
    try {
      var dot = $.CAShapeLayer.layer;
      dot.setPath($.CGPathCreateWithEllipseInRect($.CGRectMake(-5, -5, 10, 10), null));
      dot.setFillColor(cg(rgb[0], rgb[1], rgb[2], 0.95));
      var sx = winW / 2 + dir * 26, sy = 130;
      var ix = sx + dir * 105, iy = sy + 8;
      dot.setPosition($.CGPointMake(sx, sy));
      win.contentView.layer.addSublayer(dot);
      var path = $.CGPathCreateMutable();
      $.CGPathMoveToPoint(path, null, sx, sy);
      $.CGPathAddQuadCurveToPoint(path, null, sx + dir * 55, sy + 42, ix, iy);
      var fly = $.CAKeyframeAnimation.animationWithKeyPath($('position'));
      fly.setPath(path);
      fly.setDuration(0.4);
      dot.addAnimationForKey(fly, $('fly'));
      dot.setPosition($.CGPointMake(ix, iy));   // model value = end point (no snap-back)
      projectiles.push({ layer: dot, until: Date.now() + 430, ix: ix, iy: iy });
    } catch (e) {}
  }
```

`burst` gains an optional position: `function burst(rate, ms, x, y)` — when x/y given, `emitter.setEmitterPosition($.CGPointMake(x, y))` before raising birthRate; the existing done/evolve call sites pass nothing (position untouched → set it back to the default `(winW/2, 140)` whenever x/y are absent).
- [ ] **Step 3: Triggers.** In `refresh()`: replace the working-slot `burst(50, 250)` with:

```javascript
    if (p.state === 'working' && slot !== lastSlot) {
      lastSlot = slot;
      var dir = facing === 'r' ? 1 : -1;
      lunge(dir);
      fireProjectile(dir, TYPE_RGB[p.element] || TYPE_RGB[p.type] || TYPE_RGB.normal);
    }
```

Recoil: track `prevMistakes`; when `p.mistakes > prevMistakes` → `recoilUntil = Date.now() + 300`. In `move()`: waddle/recoil rotation via the transform sub-path (composes with the breathe scale animation):

```javascript
    try {
      var rot = 0;
      if (current.state === 'working') rot = 0.07 * Math.sin(t * 4.0);
      if (Date.now() < recoilUntil) rot = -0.14 * Math.sin((recoilUntil - Date.now()) / 100);
      imageView.layer.setValueForKeyPath($.NSNumber.numberWithDouble(rot), $('transform.rotation'));
    } catch (e) {}
    // projectile lifecycle: impact spark then cleanup (no extra timers)
    for (var pi = projectiles.length - 1; pi >= 0; pi--) {
      if (Date.now() >= projectiles[pi].until) {
        try {
          burst(90, 180, projectiles[pi].ix, projectiles[pi].iy);
          projectiles[pi].layer.removeFromSuperlayer;
        } catch (e) {}
        projectiles.splice(pi, 1);
      }
    }
```

- [ ] **Step 4: Isolated JXA probes FIRST** (Phase 4 lesson — a try/catch hides bridge failures): probe `CABasicAnimation` + `addAnimationForKey`, `NSMutableArray` values into `CAKeyframeAnimation`, `setPath` on a keyframe animation, and `transform.rotation` via `setValueForKeyPath` in a standalone `osascript -e` before wiring. Fix bridging per probe results.
- [ ] **Step 5: Overlay smoke** (installed off → dev overlay → `event working`, wait 8 s for a slot change → alive; `event mistake` → alive; `event done` → alive; restore). Suite green. Commit `feat: overlay pose engine and elemental attack projectiles`.

---

### Task 3: Terminal — poses + projectile line (TDD)

- [ ] **Step 1: Failing tests** (`tests/test_term.py`):

```python
class TestLiving(unittest.TestCase):
    def test_element_color(self):
        self.assertEqual(pet_term.element_color("fire"), "38;5;203")
        self.assertEqual(pet_term.element_color("holy"), "38;5;222")
        self.assertEqual(pet_term.element_color("nonsense"), "38;5;150")

    def test_projectile_line(self):
        l0 = pet_term.projectile_line(0, 1, "fire", 40)
        l3 = pet_term.projectile_line(3, 1, "fire", 40)
        self.assertIn("●", l0)
        self.assertIn("✶", l3)                      # impact frame
        self.assertLess(l0.index("●"), l3.index("✶"))
        self.assertIn("38;5;203", l0)
        left = pet_term.projectile_line(0, -1, "fire", 40)
        self.assertGreater(left.index("●"), l0.index("●"))   # starts from the right

    def test_breathe_offset(self):
        self.assertIn(pet_term.breathe_offset(0.0), (0, 1))
        self.assertNotEqual(pet_term.breathe_offset(0.0), pet_term.breathe_offset(2.0))
```

- [ ] **Step 2: Implement.**

```python
ELEMENT_256 = {"fire": 203, "water": 75, "grass": 114, "electric": 220,
               "ice": 87, "poison": 135, "psychic": 213, "normal": 187,
               "fighting": 173, "rock": 137, "ground": 179, "bug": 149,
               "flying": 153, "ghost": 141, "dragon": 105, "holy": 222,
               "dark": 99, "vpet": 150}


def element_color(element):
    return "38;5;%d" % ELEMENT_256.get(element, 150)


def breathe_offset(now):
    """One-row bob every ~2s — the terminal's breathing."""
    return int(now / 2) % 2


def projectile_line(tick, direction, element, width):
    """Frames 0..3 of the attack projectile; frame 3 is the impact."""
    span = max(10, width - 8)
    step = span // 4
    x = 4 + step * tick if direction > 0 else width - 4 - step * tick
    glyph = "✶" if tick >= 3 else "●∙∙" if direction > 0 else "∙∙●"
    return " " * max(0, x) + ESC + "[" + element_color(element) + "m" + glyph + ESC + "[0m"
```

UI wiring in `draw()`: track `self.last_slot`; on slot change while working set `self.attack_tick = 0`, direction from `self.facing_left`; while `self.attack_tick is not None and < 4`: append `projectile_line(...)` between sprite and name line, increment; else append an empty line (stable layout). Breathe: prepend `breathe_offset(now)` blank lines above the sprite (and one fewer below — total height stable). Lunge: `pad += 2 cols toward facing` on `attack_tick == 0`. Recoil: track `prev_mistakes`; on increase set `self.recoil_tick = True` → wrap sprite lines in `invert_line` for that one draw.
- [ ] **Step 3: green + headless smoke** (working state, watch two slot rotations: projectile appears then impacts; layout height stable). Commit `feat: terminal living poses and attack projectiles`.

---

### Task 4: Docs, version, QA

- [ ] README features bullet: "roams **and fights** — the sprite breathes, waddles, lunges; each attack fires an element-colored projectile matched to the move (`베이비 플레임` arcs out in fire-orange)". CLAUDE.md: add the CA-animation bridging notes to the JXA lessons (transform sub-paths compose; NSMutableArray for animation values; probe before wiring). v0.10.0.
- [ ] QA: suite macOS + Debian; overlay smoke gauntlet re-run; `pet card` unaffected; kitty/iterm terminal paths unaffected by the new ANSI-only pose lines (verify: poses/projectile line only in the ANSI sprite path — kitty/iterm skip `sprite_lines`; ADD the projectile line for them too? NO — YAGNI, graphics tiers already animate the real art; note the deliberate scope in the commit).
- [ ] Commit `docs: v0.10.0 — living pets`.

## Post-plan checks
Review loop → PASS → milestone `docs/milestones/2026-07-14-living-pets.md` → PR → auto-merge → tell the user to update.

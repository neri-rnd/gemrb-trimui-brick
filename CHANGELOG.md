# GemRB on TrimUI Brick — Changelog

All changes made to get GemRB (Planescape: Torment) running on the TrimUI Brick handheld (MuOS, A133 SoC, PowerVR GE8300 GPU, 1024x768 display).

---

# Phase 3: GemRB Master (0783b3e) + gptokeyb (current)

Synced to upstream master (commit 0783b3e, March 2 2026). Upstream absorbed many of our fixes (viewport centering, SetPlayerStat aarch64, PortraitWindow HP bars, FloatMenuWindow portrait cycling, Container flash fix, GUIOPT gamepad help text, and more). Patches and Python overrides simplified accordingly.

Build: `build.sh` → `engine.zip`
Patches: `patches/` (CORE_fixes, GLES2_fixes, GLES2_shader_fix, dialogue_customization, video_fix, dialogue_footer, pyobject_leak_fixes, freeitem_leak_fixes, audit2_fixes, audit3_fixes, colormod_fix, spellindex_fix)
Custom scripts: `custom_scripts/pst/` (MessageWindow.py, FloatMenuWindow.py, Container.py, GUIJRNL.py, GUIWORLD.py, GUISAVE.py, GUIREC.py)

---

## 47. Switch audio driver to sdlaudio

**Problem:** OpenAL Soft's connection to the sound server breaks during gameplay, causing `[ALSOFT] (EE) available update failed: Broken pipe` to spam every frame. This I/O kills performance.

**Fix (device `GemRB.cfg`):** Set `AudioDriver = sdlaudio`. SDL audio is simpler and more reliable on MuOS/TrimUI Brick.

## 46. Remove debug logging from video_fix.patch

**Problem:** Three `Log(MESSAGE, ...)` calls left from debugging in `video_fix.patch` — especially `RenderOnDisplay` which fired every frame for every render region, generating 281K log lines and hammering flash I/O on the device.

**Fix (`patches/video_fix.patch`):** Removed all three debug log statements (VideoBuffer, RenderOnDisplay, CopyPixels CONVERT). Kept the actual functional fixes (RGB555 fallback, TBDR render target unbind, inputpitch fix).

## 45. Fix upstream spell cast crash with corrupted SpellIndex

**Problem:** Casting certain abilities (e.g., TNO's Raise Dead) from the float menu fails with `RuntimeError: Wrong type of spell!` and a blank spell name. The ability appears in the list but clicking it does nothing. Upstream bug.

**Root cause:** In `Spellbook.GetUsableMemorizedSpells`, when `GetSpelldataIndex` returns -1 (spell not found in spellinfo — can happen if the SPL file lacks extended headers, or spellinfo was cleared/regenerated between list build and click), the code logs an error but still adds the spell with a corrupted index: `-1 + 4000 = 3999`. `SpellPressed` decodes this as `Type = 3999//1000 = 3` (wrong!) and `Spell = 3999%1000 = 999` (wrong!). `SpellCast(pc, 3, 999)` can't find any spell → empty spelldata → "Wrong type of spell!".

**Fix (`upstream-gemrb/gemrb/GUIScripts/Spellbook.py`):** Add `continue` after the existing -1 error log so spells with invalid indices are excluded from the list instead of being added with corrupted encoding. Also added debug logging in `FloatMenuWindow.py` to capture SpellIndex values for future diagnosis.

## 44. Fix level-up window not usable on gamepad

**Problem:** Level-up window opens but D-pad can't navigate to Accept or thief skill +/- buttons. No `Window.Focus()` called before `ShowModal()`.

**Fix (`custom_scripts/pst/GUIREC.py`):** Add `Button.MakeDefault()` on Accept button (A button triggers it) and `Window.Focus()` before `ShowModal()` (D-pad navigation works).

## 43. Fix float menu group/action buttons doing nothing

**Problem:** When multiple PCs are selected and the float menu opens in GROUP mode, the 5 action buttons (Guard, Dialogue, Attack, Stop, Search) display correctly but clicking them does nothing. Same issue with the Guard button in weapon mode. Upstream bug.

**Root cause:** `UpdateFloatMenuGroupAction` calls `Button.SetActionIcon(globals(), ...)` which constructs callback names like `"ActionDefendPressed"` and looks them up in the passed dict via `PyDict_GetItem`. But `globals()` is FloatMenuWindow.py's namespace — the callbacks are defined in `ActionsWindow.py`. The lookup returns NULL, and `PythonControlCallback(NULL)` silently creates a no-op callback.

**Fix (`custom_scripts/pst/FloatMenuWindow.py`):** Add explicit `Button.OnPress(...)` callbacks after `SetActionIcon` in both `UpdateFloatMenuGroupAction` (all 5 group action slots) and the weapon mode Guard button. `SetActionIcon` is kept for visual setup (icons, tooltips, hotkeys). Added `_GroupActionPress` helper that closes the menu then fires the action callback — same pattern used by the working thieving/spell buttons.

## 42. Fix upstream spell tint persisting forever

**Problem:** Casting a spell that applies a color tint (opcode 0x08 Color:SetRGB with location=0xff, or Color:SetRGBGlobal) causes the tint to persist on the character forever instead of clearing when the effect expires. Upstream bug in `CharAnimations::CheckColorMod()`.

**Root cause:** Asymmetry between global and local ColorMod clearing. Local mods check `!phase` (phase=0 for permanent effects → clears correctly). Global mod checks `!locked` — but `SetColorMod(phase=0)` sets `locked=true`, and nothing ever resets it for permanent effects (speed=-1). `PulseRGBModifiers` only resets locked inside a `speed > 0` block, unreachable for permanent tints.

**Fix (`colormod_fix.patch`):** Add `GlobalColorMod.locked = false;` at the start of `CheckColorMod()`. Each tick, the lock is reset; active effects re-lock via `ApplyAllEffects → fx_set_color_rgb → SetColorMod`. Expired effects don't re-lock, so the existing `!locked` check clears the mod. No visual flicker — rendering happens after both CheckColorMod and ApplyAllEffects complete.

## 41. Upstream bug audit round 3 — GetContainerItem dict leak

**Problem:** Third-pass audit focusing on float menu, item use, spell casting, and related Python/C++ flows. Found 1 confirmed C++ bug (plus 2 upstream Python bugs already fixed in our FloatMenuWindow.py override).

**Fix (`audit3_fixes.patch`):**

1. **GUIScript.cpp `GetContainerItem` — dict leak on unresolvable item:** `PyDict_New()` creates a dict populated with 5 entries (ItemResRef, Usages0-2, Flags), then calls `gamedata->GetItem()`. If the item ResRef doesn't resolve (corrupted save, mod remnant), the function returns `Py_RETURN_NONE` without freeing the dict — leaking the dict header + 5 PyObject values. Fix: add `Py_DecRef(dict)` before the early return. PST-reachable via Container.py calling `GemRB.GetContainerItem()` for each container slot.

**Upstream Python bugs (already fixed in our override):** FloatMenuWindow.py `UseSpell` uses `type` (Python builtin) instead of `spelltype` — would crash on any spell cast from float menu. `RefreshSpellList` declares `global type` instead of `global spelltype` — the global never gets updated.

**Verified false positives:** TryUsingMagicDevice null deref (IWD2-only code path), QuickSpells OOB (constrained by Python UI), Inventory Usages logic (intentional fallback), GetSpell/GetExtHeader null (requires corrupted SPL), GetSlotItem PCStats null (PST PCs always have it), float menu spell wrap off-by-one (correct — compensates for subsequent -1), float_menu_selected negative (intentional absolute index preservation).

## 40. Upstream bug audit round 2 — ChunkActor null deref + SetPLT key leak

**Problem:** Second-pass audit of upstream GemRB (commit 3a52c5fd48) after fixing the major leak classes in #39. Found 2 confirmed bugs out of ~40 candidates examined across Actor.cpp, Actions.cpp, Matching.cpp, Map.cpp, Game.cpp, Inventory.cpp, and GUIScript.cpp.

**Fix (`audit2_fixes.patch`):**

1. **Actor.cpp `ChunkActor` — null map dereference (PST-reachable):** `GetCurrentArea()` can return NULL during area transitions. `ChunkActor` immediately dereferences it via `map->IsVisible()` without a null check. If an actor dies with gore enabled while between areas, this crashes. Fix: add `if (!map) return;` before the `IsVisible` call, matching the existing pattern in `pcf_avatarremoval`.

2. **GUIScript.cpp `Button_SetPLT` — PyLong dict key leak (not PST-reachable):** `PyDict_GetItem(colors, PyLong_FromLong(keys[i]))` creates a temporary PyLong that is never freed. PyDict_GetItem only borrows a reference to the value; the key is simply abandoned. Leaks 8 PyLong objects per SetPLT call. Fix: extract to temp variable + `Py_DecRef(key)`. Only affects BG1/BG2/IWD (PST has no paper dolls).

**Verified false positives:** PythonControlCallback NULL (safe by design), IE_CLASS=0 OOB (classless creatures skip RefreshHP), IE_MAXHITPOINTS div-by-zero (all actors have positive max HP), stealth div-by-zero (constant denominator), bit shift OOB (bounded spell schools), FindPC(1)/GetPC() null (guaranteed valid in PST). ~30 additional `GetCurrentArea()` null derefs in Actions/Matching are real but unreachable during normal script execution.

## 39. Fix upstream memory leaks — PyObject refs + Item cache refcounts

**Problem:** Deep audit of upstream GemRB (commit 3a52c5fd48) found two systematic bug classes causing unbounded memory growth during gameplay — especially impactful on the 1GB TrimUI Brick:

1. **PyObject reference leaks in GUIScript.cpp:** `PyDict_SetItemString()` does NOT steal references, but many callsites pass bare `Py*_From*()` without the codebase's own `DecRef` RAII wrapper. ~100 leaked PyObjects across 17 functions, including high-frequency paths like `GetSlotItem` (8/call), `GetCombatInfo` (~47/call), `GetSpell` (15/call), and `GetItem` (6/call). Also includes an error-path dict leak in `GetCombatInfo` and sub-dict/tuple leaks not DecRef'd after `PyDict_SetItemString`.

2. **Item cache refcount leaks (missing `FreeItem`):** `gamedata->GetItem()` increments a cache refcount; `gamedata->FreeItem()` decrements it. Missing `FreeItem` on any code path = item never evicted from cache. Found 11 leak sites across Actor.cpp, Interface.cpp, STOImporter.cpp, Inventory.cpp, Actions.cpp, Map.cpp, and GUIScript.cpp.

**Fix (`pyobject_leak_fixes.patch`):**
- Wrap all bare `PyLong_FromLong()`, `PyString_FromResRef()`, `PyBool_FromLong()`, `PyString_FromStringObj()`, `PyObject_FromHolder()` calls in `DecRef()` RAII wrapper when passed to `PyDict_SetItemString()`
- Add `Py_DecRef()` for tuples and sub-dicts after insertion into parent dict (GetPCStats 6 tuples, GetStoreInfo 2 tuples, GetCombatInfo ac/tohits/alldos sub-containers)
- Fix error-path dict leak in `GetCombatInfo` (`Py_DecRef(dict)` before `RuntimeError()`)
- Fix `PyList_Append` leak in module init (use temp variable + `Py_DecRef`)
- Fix 2 missing `FreeItem` calls in `DragItem` (cursed item and CRI_EQUIP early returns)

**Fix (`freeitem_leak_fixes.patch`):**
- `Actor::GetArmorCode()`: Restructure to single return with `FreeItem` (was leaking on every armor sound lookup)
- `Actor::GetItemInfo()`: Add `FreeItem` on `!ext_header` early return
- `Interface::ItemDragOp()`: Add `FreeItem` after reading icon sprites (was leaking on every inventory drag)
- `STOImporter::GetStore()`: Add `FreeItem` in item loop — both invalid-item and normal paths
- `Inventory::EnforceUsability()`: Add `FreeItem` after `Unusable()` check, before continue
- `Inventory::GetEquippedExtHeader()`: Add `FreeItem(false)` after extracting ext header pointer (safe — cache retains item)
- `Inventory::EquipItem()`: Add `FreeItem` on 2 broken-save `!header` early returns
- `Inventory::CacheWeaponInfo()`: Add `FreeItem` on `!hittingHeader` early return
- `Actions::UseItem()`: Add `FreeItem` on 3 early return paths (`!hh`, dead target, avatar removal)
- `Map::GetItemByDialog()`: Add `FreeItem` on dialog mismatch continue + match path

## 38. Dialogue "Scroll Down" Indicator

**Problem:** With 22px Literata font, dialogue text and options often overflow the visible TextArea. After the scroll-start fix (#37), NPC text appears from the top, but there was no visual cue that more content existed below the fold. Users had to guess whether to scroll.

**Fix (`dialogue_footer.patch` + MessageWindow.py + GUIWORLD.py):**

C++ patch exposes TextArea scroll state to Python:
- `ScrollView`: Added `ScrollNotifier` callback, fires on every scroll change from `UpdateScrollbars()`
- `TextArea`: Added `GetScrollInfo()` returning `{content, visible, pos}` dict, plus `Action::Scroll` event
- `GUIScript`: New `TextArea_GetScrollInfo` Python binding
- `GUIClasses`: Registered `GetScrollInfo` method and `OnScroll()` convenience handler

Python changes create a 22px footer strip at the bottom of the dialogue window:
- TextArea shrunk by 22px (264 -> 242) to make room
- "scroll down" label centered in footer, warm orange, shown when content overflows below
- Continue/End button moved to same footer position (invisible background, text-only)
- Arrow and button share the space — arrow hides when button has text, and vice versa
- `OnScroll` hook reactively updates indicator on every D-pad scroll
- `UpdateFooterArrow()` called from `UpdateControlStatus`, `NextDialogState`, `OpenContinueMessageWindow`, `OpenEndMessageWindow`; arrow hidden in `DialogStarted`/`DialogEnded`

---

## 37. Dialogue Auto-Scroll Fix (Show Exchange Start Instead of Bottom)

**Problem:** With FONTDLG increased to 22px Literata, PST dialogue text no longer fits in the 288px dialogue window. GemRB's PST-specific auto-scroll (`DIALOGUE_SCROLLS` feature flag) scrolled to the absolute bottom (`y = 9999999`), hiding the beginning of the NPC's response. The user had to manually scroll back up to read from the start.

**Root cause:** In `TextArea::UpdateScrollview()`, the PST path hardcoded `y = 9999999` to scroll to the bottom. Non-PST games used `y = nodeBounds.y - LineHeight()` (scroll to dialogue begin marker) which is much better, but PST's animated scroll behavior required a different approach.

**Fix (`dialogue_scroll_fix.patch`, TextArea.h/cpp + DialogHandler.cpp):**

1. Added `dialogScrollTarget` field to `TextArea` — records text container height before each new dialogue exchange
2. `DialogHandler::DialogChoose()` calls `ta->MarkDialogStart()` before NPC text is appended, capturing the scroll position where the new exchange begins
3. `TextArea::UpdateScrollview()` PST path now scrolls to `dialogScrollTarget` instead of `9999999`. Falls back to `nodeBounds.y - LineHeight()` if no target is set
4. `DialogHandler::EndDialog()` calls `ta->ClearDialogStart()` so non-dialogue text (combat messages, etc.) uses normal bottom-scroll
5. `TextArea::ClearText()` resets the target for clean state

**Result:** NPC response is visible from the first line. For long text, the user scrolls down with D-pad (upstream's 1-line-per-press native scrolling). Short text shows both NPC text and options without change.

---

## 36. Sync to Upstream Master (0783b3e)

**Context:** The upstream gemrb developer reviewed our submitted bug reports and merged several fixes. He reported that "the core patch is no longer needed (except possibly viewport centering cancellation), at least half the dialogue customization patch is redundant, and several Python overrides can go." He also added native gamepad proxy/hotkey support, made up/down buttons work in the message window, and fixed 1-line-per-press scrolling.

**Changes made:**

### CORE_fixes.patch — stripped 2 redundant hunks
- **Dropped** `GameControl.cpp` viewport centering hunk — upstream now has `p.y += mwinh / 2` (equivalent fix; centers NPC in visible strip above window)
- **Dropped** `GUIScript.cpp` SetPlayerStat hunk — upstream fixed `stat_t` vs `long` mismatch with identical approach
- **Kept** `Window.cpp` mouse drag guard (gptokeyb D-pad still sends buttonless mouse motion events)
- **Kept** `Window.cpp` Esc-during-dialogue block (prevents B button closing dialogue on gamepad)
- **Kept** `Inventory.cpp` same-slot equip animation update
- **Kept** `Actor.cpp` stance recovery for missing animation BAMs
- **Kept** `GUIScript.cpp` DragItem weapon removal animation trigger

### Python overrides — removed 4 redundant files
- **Removed** `PortraitWindow.py` — HP bar hiding for empty slots now in upstream
- **Removed** `GUIOPT.py` — gamepad help text on button press now in upstream
- **Removed** `GUIMG.py` — debug prints gone, event proxy now in upstream
- **Removed** `GUIPR.py` — same as GUIMG.py

### build.sh — updated commit hash
- `GEMRB_COMMIT` bumped from `bc6e075` → `0783b3e`

**Upstream changes that benefit us (no action required):**
- Native message window up/down key scrolling (1 line per press)
- More hotkey proxies (L/R spellbook navigation, focus forwarding)
- FloatMenuWindow two-fix merge from nerifuture (portrait cycling + item use)
- Container flash-on-close fix merged upstream
- MoveViewportTo "exact center" formula corrected (mwinh/2)

---

## 35. Fix Map Pins Bunched Together (PST autonote.ini Coordinate Bug)

**Problem:** In the area map view, location pins (Mortuary, Mausoleum, etc.) were all clustered in the top-left corner instead of being spread across the map at their correct positions.

**Root cause:** Two bugs in `AREImporter::GetAutomapNotes()`:

1. **Missing coordinate conversion in INI path.** When `NoteCount == 0` (first visit to an area), map notes are loaded from `autonote.ini`. These coordinates are in **small-map pixel space** (e.g., x=136 on a 432px-wide minimap), but the code stored them directly as game-world coordinates without converting. `MapControl::ConvertPointFromGame()` then divides by the full map size (e.g., 4608), producing screen positions like `136 * 432 / 4608 ≈ 13px` — all pins collapse to the top-left corner.

2. **Corrupted coordinates persist in saves.** After the first visit, notes are saved to the ARE file. The save path correctly converts game-world coords back to small-map space — but since the "game" coords were actually tiny small-map values, they get divided again, producing even smaller numbers (e.g., 3, 6, 12). On reload, these corrupted values are used, and the pins remain permanently wrong.

**Fix (`map_pin_fix.patch`, AREImporter.cpp):**
- Added small-map → game-world conversion to the `autonote.ini` loading path, matching the existing ARE loading path
- Readonly system notes from saved ARE data are now skipped; they are always re-read from `autonote.ini` with correct coordinates. This repairs existing corrupted saves without requiring a new game.
- User-added notes (readonly=false) are still loaded from the ARE save as before.

**Requires rebuild** (C++ change).

---

## 34. Fix Level-Up Window Text Truncation (14px TTF Font Override)

**Problem:** The level-up screen had text truncation — "SAVING THROWS" showed as "Saving...", thief skill labels overflowed, and the overview text was oversized. This happened because FONTDLG was changed from 14px BAM to 20px Literata TTF for better dialogue readability, but the CHU label widths in window 4 were designed for the smaller font.

**Fix:**
- Added `MEDIUMDLG` font entry to `fonts.2da` — Literata TTF at 14px, giving a TTF font that fits the CHU label dimensions
- `GUIREC.py` overrides all level-up window labels and the overview TextArea to use `MEDIUMDLG`, preserving original yellow text colors

**Files:** `custom_scripts/pst/GUIREC.py`, `device/games/pst/override/fonts.2da`

No rebuild needed — Python overlay + 2DA.

---

## 33. Fix Character Tint Blinking at Dusk/Night (GLES2 Shader-Side Tint)

**Problem:** Characters randomly appear darker with brownish-yellow (dusk) or bluish (night) tint that blinks on/off during dusk/night hours. The issue is purely in the rendering pipeline — game logic tint values are correct.

**Root cause:** For paletted sprites (actors), tint was baked into the palette CPU-side via `ShadePalette()`, then the texture re-uploaded every draw call. Sprites are shared between actors, and each actor's draw applies a different position-specific tint (area lighting varies by position). The shared palette oscillates between tint values across draws, causing some actors to show the wrong tint.

**Fix:** On GLES2 builds, skip the CPU-side palette shading entirely. The shader already has full infrastructure for this — `RenderCopyShaded()` builds quads with per-vertex color from the tint when `COLOR_MOD`/`ALPHA_MOD` flags are set, and the fragment shader applies multiplicative tint (`texel * v_color`) plus greyscale/sepia (`u_greyMode`). By returning `BlitFlags::NONE` from `PrepareForRendering()`, the tint flags flow through to the shader instead of being consumed by palette baking. The palette stays at base colors and the texture only re-uploads when the actual base palette changes (rare).

**Files:** `GLES2_shader_fix.patch` (`SDLSurfaceSprite2D.cpp` — `#if USE_OPENGL_BACKEND` guard in `PrepareForRendering()`). Also removed diagnostic logging from `CORE_fixes.patch` (Map.cpp tint tracing hunk).

---

## 32. Fix Characters Disappearing During Spell Casting (Morte Litany of Curses)

**Problem:** Three related animation bugs:
1. Morte disappears when casting Litany of Curses — only reappears on movement
2. Characters sometimes blink/flicker during spell sequences
3. Related stance-stuck issues when animation BAMs are missing

**Root cause:** When an actor enters a stance with no BAM animation file (e.g. Morte has no CONJURE BAM — he's a floating skull), `GetAnimation()` returns nullptr, `currentStance.anim` is cleared, and `Draw()` returns early → character invisible. The critical bug is in `UpdateActorState()` (Actor.cpp:7835): when `anim.empty()`, it returns WITHOUT calling `HandleActorStance()`. Even though `GetAnimation()` set `autoSwitchOnEnd = true` and `nextStanceID = IE_ANI_READY`, the auto-switch code is never reached. The actor is stuck invisible forever.

**Spell casting flow:** `SetStance(IE_ANI_CAST)` → spell executes → `CastSpellEnd()` → `SetStance(IE_ANI_CONJURE)` → (should auto-switch to `IE_ANI_READY`). For Morte (0x2E, PST_ANIMATION_3), `IE_ANI_CAST` works (stances.2da overrides to HEAD_TURN), but `IE_ANI_CONJURE` has no override and no BAM → permanent invisibility.

**Fix (two layers):**

*Engine recovery (`CORE_fixes.patch`, Actor.cpp `UpdateActorState()`):*
```cpp
if (anim.empty()) {
    CharAnimations* ca = GetAnims();
    if (ca && ca->autoSwitchOnEnd) {
        HandleActorStance();  // transition to valid stance
    } else {
        SetStance(IE_ANI_AWAKE);  // fallback to idle
    }
    UpdateModalState(game->GameTime);
    return;
}
```
Fixes all actors with missing stance animations, not just Morte.

*Data prevention (`build.sh` sed, stances.2da):* Added `0x2e 3 6` override — maps Morte's CONJURE (3) to HEAD_TURN (6), so the missing BAM is never even attempted. Belt-and-suspenders with the engine fix.

**Requires rebuild** (C++ change + build script).

---

## 31. Mage/Priest Spell Info Scrollbar, Save Game Scrollbar, Options Help Text

**Problem:** Several upstream PST scripts had gamepad usability issues:
- Mage spell window (`GUIMG.py`) had debug `print()` statements spamming the log on every refresh
- Spell info popups (mage + priest) couldn't scroll long descriptions with D-pad
- Save game window couldn't scroll through save slots with D-pad (GUILOAD already could)
- Options sub-windows showed help text only on mouse hover, invisible to gamepad users

**Fix (4 new Python overlays):**
- `GUIMG.py`: Removed debug prints (`max_mem_cnt`, `mem_cnt`); added `Window.SetEventProxy(Text)` to spell info window for gamepad scrolling
- `GUIPR.py`: Added `Window.SetEventProxy(Text)` to priest spell info window for gamepad scrolling
- `GUISAVE.py`: Added `Window.SetEventProxy(ScrollBar)` + `SaveWindow.Focus()` for D-pad save slot scrolling; fixed upstream bug where `SetVarAssoc` was missing min/max range args (scrollbar was locked with 5+ saves)
- `GUIOPT.py`: Modified `PSTOptButton` to show help text on button press (not just hover), so gamepad users see descriptions when activating Feedback/Autopause sub-menus

No rebuild needed — Python overlays.

---

## 30. Fix Newline in Dialogue Continue/End Buttons + Remove Formation Debug Print

**Problem:** The Continue and End dialogue buttons showed multi-line text because the string table entries (strrefs 34602, 34603, 28082) contain embedded newlines. On the 640x28 full-width button bar, this caused text to overflow or wrap awkwardly. Additionally, `SelectFormation()` had a leftover `print("FORMATION:", formation)` debug statement that spammed the log.

**Fix (GUIWORLD.py, Python-only):**
- `OpenEndMessageWindow()`: `Button.SetText(GemRB.GetString(34602).replace('\n',' ').strip())` — strip newlines from "End Dialogue" string
- `OpenContinueMessageWindow()`: `Button.SetText(GemRB.GetString(34603).replace('\n',' ').strip())` — strip newlines from "Continue" string
- `DialogEnded()`: `Button.SetText(GemRB.GetString(28082).replace('\n',' ').strip())` — strip newlines from "Close" string
- `SelectFormation()`: Removed `print("FORMATION:", formation)` debug line

No rebuild needed — Python overlay.

---

## 29. Fix Weapon Animation Not Updating on Equip/Remove

**Problem:** Changing weapons in PST inventory never updates the in-game character sprite animation. Dragging the axe out and equipping a dagger (or any other weapon, in any slot) keeps showing the axe animation. The item icon and paperdoll update, but `IE_ANIMATION_ID` stays stale — `pcf_animid` never fires.

**Root causes (three bugs):**

1. **`SetPlayerStat` stack overflow on aarch64 (primary).** `GemRB_SetPlayerStat()` in `GUIScript.cpp` uses `PARSE_ARGS(args, "iIl|i", ..., &StatValue, &pcf)` where `StatValue` is `stat_t` (4 bytes, `uint32_t`) but the `l` format specifier writes a C `long` (8 bytes on aarch64). `PyArg_ParseTuple` writes 8 bytes into the 4-byte `StatValue`, and the upper 4 zero bytes overflow into the adjacent `pcf` variable on the stack, setting it to 0. With `pcf=0`, `SetCreatureStat` calls `SetBaseNoPCF` instead of `SetBase` — so `pcf_animid()` never fires, `SetAnimationID()` is never called, and the sprite never changes. The stat value itself gets updated (visible via `GetPlayerStat`), but the post-change function that creates new `CharAnimations` is silently skipped. This affects ALL `SetPlayerStat` calls from Python on aarch64 (LP64) — any stat with a PCF (animation, colors, state flags) won't trigger its callback.

2. **Weapon removal never triggers animation update.** `GemRB_DragItem()` calls `TryToUnequip()` → `UnEquipItem(Slot, false)` with `removeBonuses=false`, which skips `RemoveSlotEffects()`, so `EF_UPDATEANIM` is never set. Dragging a weapon OUT of a slot never triggers `UpdateAnimation()`.

3. **Same-slot equip skips animation update.** `Inventory::EquipItem()` has an early return when `Equipped == equip && EquippedHeader == newHeader`, skipping the `SetEquippedSlot()` → `UpdateWeaponAnimation()` → `EF_UPDATEANIM` chain.

**PST animation update chain:** `EF_UPDATEANIM` → Python `UpdateAnimation()` → reads weapon's `AnimationType` → looks up `ANIMS.2da` → `SetPlayerStat(IE_ANIMATION_ID, value)` → `pcf_animid()` → new `CharAnimations`. Bug #1 breaks the last step (PCF never fires). Bugs #2 and #3 break the first step (`EF_UPDATEANIM` never set).

**Diagnostics used:**
- Python `print()` logging in `UpdateAnimation()` confirmed the function IS called, ANIMS.2da lookups succeed, and `SetPlayerStat` IS called with correct values (AX→0x602f, DD→0x6031, CL→0x6030, WH→0x6033)
- C++ `Log()` in `pcf_animid` and `SetAnimationID` confirmed they NEVER fire for runtime weapon changes — only during initial actor load. This proved the bug was in the SetStat→PCF dispatch path, leading to the `l`/`stat_t` size mismatch discovery.

**Fix (`CORE_fixes.patch`, three hunks in GUIScript.cpp + one in Inventory.cpp):**

*GUIScript.cpp — `GemRB_SetPlayerStat()`:* Use `long` to match the `l` format specifier, then cast:
```cpp
long StatValueLong;
int pcf = 1;
PARSE_ARGS(args, "iIl|i", &globalID, &StatID, &StatValueLong, &pcf);
stat_t StatValue = static_cast<stat_t>(StatValueLong);
```

*GUIScript.cpp — `GemRB_DragItem()`:* Set `EF_UPDATEANIM` after weapon removal:
```cpp
int slotEffects = core->QuerySlotEffects(core->QuerySlot(Slot));
if (slotEffects == SLOT_EFFECT_MELEE || slotEffects == SLOT_EFFECT_MISSILE) {
    core->SetEventFlag(EF_UPDATEANIM);
}
```

*Inventory.cpp — `EquipItem()`:* Re-cache weapon info before same-slot early return:
```cpp
CacheAllWeaponInfo();
UpdateWeaponAnimation();
```

**Verified** — all weapon animations update correctly on device (axe, dagger, club, warhammer, fist).

---

## 28. Video Playback Fix (MVE Cutscenes)

**Problem:** PST cutscene videos (MVE format) played as a BLACK screen on the TrimUI Brick. Only the first video (BISLOGO) was affected — the second and third (TSRLOGO, OPENING) rendered correctly.

**Root cause: TBDR render-target conflict.** The `SDLTextureVideoBuffer` constructor calls `Clear()`, which binds the video texture as an FBO render target (`SDL_SetRenderTarget(renderer, texture)`) and issues `SDL_RenderClear`. On PowerVR GE8300 (TBDR architecture), the clear is deferred in the tile buffer. The first `CopyPixels` call then uploads pixel data via `SDL_UpdateTexture` (`glTexSubImage2D`) while the texture is still the active FBO color attachment. When the FBO later resolves, the deferred clear overwrites the uploaded pixels — frame 1 is black, and the GPU texture cache stays corrupted for all subsequent frames. Videos 2 and 3 worked because the previous video's render cycle left the renderer in a clean state (RT already unbound).

**Fix (`video_fix.patch`, SDL20Video.h):**
- Added `SDL_SetRenderTarget(renderer, NULL)` at the start of `CopyPixels()`, before any `SDL_UpdateTexture` call — forces the TBDR GPU to resolve pending operations before new pixel data is uploaded
- Safe for all code paths: frame 1 resolves the pending Clear; frame 2+ is a no-op (RT already NULL)
- Also includes: center-pixel diagnostic logging (replaces corner pixel, which is always black in logo videos), frame counter, RGB555→ABGR8888 format conversion fixes

**Result:** All 3 intro videos (BISLOGO, TSRLOGO, OPENING) render correctly. No regressions to game UI or sprites.

**Requires rebuild** (C++ change, new patch file).

---

## 27. Keyboard Scroll Speed Reads Game Setting

**Problem:** The in-game "Keyboard Scroll Speed" slider (Settings menu) had no effect on TextArea scrolling. The slider value was stored in the game dictionary but never read by the scrolling code.

**Root cause:** When the scrollbar is focused (our fix for keyboard scrolling in entries #9/#26), `ScrollBar::OnKeyPress` handles key events — not `ScrollView::OnKeyPress`. ScrollBar called `ScrollUp()`/`ScrollDown()` → `ScrollBySteps(±1)`, which scrolls by a fixed `StepIncrement` (set from the CHU definition). The game setting was never consulted. The previous `ScrollView::OnKeyPress` fix (entry #13's `StepIncrement * 3`) was also dead code for the same reason — it only ran when ScrollView handled keys directly (no focused scrollbar).

**Fix (`dialogue_customization.patch`, ScrollBar.cpp + ScrollView.cpp):**
- `ScrollBar::OnKeyPress`: Read `core->GetDictionary().Get("Keyboard Scroll Speed", 64)`, convert to steps via `scrollSpeed / StepIncrement`, call `ScrollBySteps(±steps)` instead of `ScrollUp()`/`ScrollDown()`
- `ScrollView::OnKeyPress`: Also reads the game setting (fallback path when no scrollbar is focused)
- Added `#include "Interface.h"` to both files for access to the `core` global
- Default 64 matches the game's default slider value

**Requires rebuild** (C++ change).

---

## 26. Journal Keyboard Scrolling

**Problem:** L1/L2 (up/down keys) worked for scrolling in the dialogue window and inventory descriptions, but not in the Journal. Opening Journal > Log/Quests/Beasts and pressing L1/L2 did nothing — you had to click the scrollbar first.

**Root cause:** `OpenLogWindow()` calls `LogWindow.Focus()` which focuses the **Window**, not the TextArea's ScrollBar. Key events go only to the focused control (`Window::DispatchKey`). Since the Window itself was focused, arrow keys never reached the TextArea's internal ScrollView. Compare with dialogue (`MessageWindow.py:182-184`) which correctly calls `sb.Focus()` on the TextArea's scrollbar.

**Fix (GUIJRNL.py, Python-only):**
- Created PST-specific `GUIJRNL.py` override in `custom_scripts/pst/` (shadows upstream via GUIScripts path priority)
- `OpenLogWindow()`: After `Text.SetText()` and `LogWindow.Focus()`, focus the TextArea's scrollbar
- `OnJournalQuestSelect()`: After setting quest description text, focus QuestDesc's scrollbar
- `OnJournalBeastSelect()`: After setting beast description text, focus BeastDesc's scrollbar

Pattern used (same as MessageWindow.py):
```python
sb = TextArea.GetScrollBar()
if sb:
    sb.Focus()
```

No rebuild needed — Python overlay, picked up by next `build.sh`.

---

## 25. Font Differentiation — ButtonFont = NORMAL

**Problem:** After switching the dialogue font to Literata TTF 18px (entry #14), the same font was also used for button labels, menu items, item descriptions, and other UI elements that should use the original bitmap font. Everything looked the same — no visual distinction between dialogue text and UI chrome.

**Root cause:** GemRB's `fonts.2da` row 0 (`FONTDLG`) is the default font used everywhere. Overriding it to TTF affected all text, not just dialogue. The `ButtonFont` setting in `gemrb.ini` controls which font is used for buttons and UI elements, but it defaulted to the same `FONTDLG`.

**Fix (`gemrb.ini` + `build.sh`):**
- Set `ButtonFont = NORMAL` in `unhardcoded/pst/gemrb.ini` — points buttons/UI to `fonts.2da` row 9 (the original bitmap BAM font)
- Dialogue text uses Literata TTF 18px, UI chrome uses original PST bitmap font
- Added `sed` step in `build.sh` to patch `ButtonFont` after install — persists across rebuilds (the previous manual device edit was overwritten by `engine.zip` deploys)

---

## 24. Fix Dialogue Window Flash When Opening/Closing Chests

**Problem:** When opening or closing a chest (container), the custom dialogue window (dark 288px overlay) briefly flashed on screen for 1-2 frames.

**Root cause:** The shared `Container.py` calls `GemRB.GetView("MSGWIN").SetVisible(True)` when closing a container, to restore the message window. In upstream PST, MSGWIN is a small 192px window — the brief flash is unnoticeable. In our custom PST, MSGWIN is permanently styled as a 288px dark semi-transparent overlay (set in `MessageWindow.py:OnLoad()`). `Window::Close()` without `DestroyOnClose` just calls `SetVisible(false)` (Window.cpp:63), so Container.py's `SetVisible(True)` directly reverses it, making the full dialogue overlay flash visible. `GUICommonWindows.py:487,540` already guard MSGWIN visibility with `if not IsPST()` — Container.py was the only place missing this guard.

**Fix (Container.py, Python-only):**
- Created PST-specific `Container.py` override in `custom_scripts/pst/` (GemRB's Python path puts `GUIScripts/pst/` before `GUIScripts/`, so it shadows the shared version)
- Removed `MSGWIN.SetVisible(False)` from `OpenContainerWindow()` — redundant, MSGWIN already Close()'d by UpdateControlStatus
- Removed `MSGWIN.SetVisible(True)` from `CloseContainerWindow()` — this was the flash. MSGWIN stays hidden until `UpdateControlStatus()` shows it for actual dialogue via `MWindow.Focus()`
- ACTWIN hide/show during container kept (correct behavior)

---

## 23. Fix Portrait Selection Outline When Cycling PCs in Float Menu

**Problem:** When cycling through party members via the float menu's portrait button, the green selection outline in the bottom portrait bar didn't update — it stayed on the previously selected PC.

**Root cause:** GemRB has two separate PC selection mechanisms: `game->selected` (multi-select vector, updated by `GameSelectPC`) and `game->SelectedSingle` (single-focus int, updated only by `GameSelectPCSingle`). The portrait outline checks `SelectedSingle` when `SelectionChangeHandler` is active (float menu open). `FloatMenuSelectNextPC` and `FloatMenuSelectPreviousPC` only called `GameSelectPC` — never updating `SelectedSingle`. Compare: `PortraitButtonOnPress` (GUICommonWindows.py:639) correctly calls `GameSelectPCSingle` when a handler is set.

**Fix (FloatMenuWindow.py, Python-only):**
- Added `GemRB.GameSelectPCSingle(pc)` before `GameSelectPC` in both `FloatMenuSelectNextPC` and `FloatMenuSelectPreviousPC`
- `SelectedSingle` is set BEFORE `GameSelectPC` fires `EF_SELECTION` → `SelectionChanged()` → `UpdatePortraitWindow()`, so the outline reads the correct value

---

## 22. Hide Health Bars for Empty Party Slots

**Problem:** Health bars (FILLBAR BAM) were visible for all 6 portrait slots, even when no party member occupied the slot. Only TNO is present at game start, but slots 2-6 showed empty green bars.

**Root cause:** `UpdatePortraitButton()` in `PortraitWindow.py` hides the portrait button (`SetVisible(False)`) for empty slots and returns early, but the health bar is a separate control (ID = `6 + ControlID`) that was never hidden.

**Fix (PortraitWindow.py, Python-only):**
- Added `ButtonHP.SetVisible(False)` in the empty-slot early-return block
- Added `ButtonHP.SetVisible(True)` in the occupied-slot path (ensures bar reappears when a new party member joins)

---

## 21. Float Menu Item Use — Reliability Fixes

**Problem:** Using items from the radial float menu had three reliability issues:
1. Targeting sometimes didn't trigger when clicking a target (multi-select: `ACT_CAST` requires `game->selected.size() == 1`)
2. With multiple PCs selected, bandage applied to self instead of clicked target
3. Misleading "cast" cursor appeared when entering the items sub-menu before any item was selected

**Root causes:**
- `FloatMenuSelectItems()` called `GameControlSetTargetMode(TARGET_MODE_CAST)` on sub-menu entry — before any item was selected. For TARGET_SELF items this showed a confusing cast cursor; for TARGET_CREA items it was redundant (UseItem sets it via C++ `SetupItemUse`)
- C++ `PerformActionOn` ACT_CAST path requires exactly 1 selected PC. Float menu can be opened in group mode with multiple PCs selected

**Fix (FloatMenuWindow.py, Python-only):**
- Removed premature `GameControlSetTargetMode(TARGET_MODE_CAST)` from `FloatMenuSelectItems()` — targeting mode now set by `UseItem` → C++ `SetupItemUse` only when an actual item is selected
- Added `GameSelectPC(pc, 1, SELECT_REPLACE | SELECT_QUIET)` in `UseItemDirect()` — narrows selection to the acting PC before `UseItem`, ensuring `game->selected.size() == 1` for the C++ ACT_CAST targeting path
- Added `if not pc: return` guard to prevent `GameSelectPC(0, ...)` which would select ALL PCs

---

## 20. Continue Button — Full-Width Click Area

**Problem:** The Close/Continue button at the bottom of the dialogue window was resized from 64x64 (CHU default) to 640x28 via `SetFrame()`, but the BAM sprite highlight still rendered at the original 64px size in the left corner. `Button::HitTest` also checked the small BAM sprite's pixel transparency, so clicks outside the ~64px area were ignored.

**Fix (MessageWindow.py, Python-only):**
- `SetSprites("", ...)` — clears all 4 BAM images → no corner highlight, full 640x28 frame clickable
- `SetBackground({'r':35,'g':35,'b':45,'a':200})` — subtle dark bar (slightly more opaque than MWindow's `a=144`)
- `SetColor({'r':180,'g':200,'b':220,'a':255})` — soft blue-white text matching dialogue theme
- `PushOffset` text shift on press still provides tactile feedback

---

## 19. Dialogue Window Resize — 60% Screen Height + 18px Font

**Fix (MessageWindow.py + fonts.2da, Python-only / data):**
- Window height: 480px → **288px** (60% of 480 — visible game strip: 192px above dialogue)
- Font: Literata 22px → **18px** (better fit for smaller window)
- Viewport pan (entry #17) centers NPC in the 192px visible strip (`mwinh/2 = 144` offset)

---

## 18. Fullscreen Dialogue Window

**Problem:** With the dialogue window at 424/480px, a 56px game world strip was visible above it. The viewport pan (entry #17) centered the NPC in this strip, but it was too thin to be useful and the map was distractingly visible through the semi-transparent background.

**Fix (MessageWindow.py, Python-only):**
- Window height: 424px → **480px** (fullscreen)
- Background alpha: 180 → **144** (20% more transparent — game world visible as atmosphere behind dialogue)
- Viewport pan is automatically suppressed (entry #17: `mwinh >= viewport.h` → skip pan)

---

## 17. Fix Viewport Pan During Dialogue (C++)

**Problem:** When dialogue opens, `DialogHandler` calls `gc->MoveViewportTo(tgt->Pos, true, DIALOG_MOVE_SPEED)` to pan the viewport and center the NPC on screen. The centering formula `p.y += mwinh` (offset by full message window height) was designed for a ~192px window. With our 424px window, this pushed the NPC **184px above the top of the screen** — completely invisible. The animated pan (~500ms) caused the map to visibly scroll behind the dialogue window.

**Root cause:** `p.y += mwinh` is a linear offset. GlobalTimer then subtracts `viewport.h/2` to center. For a 192px window: NPC at y=48 (fine). For a 424px window: NPC at y=-184 (off-screen). The correct offset is `mwinh/2`, which places the NPC at `(viewport.h - mwinh) / 2` — the exact center of the visible strip for any window height.

**Fix (`CORE_fixes.patch`, `GameControl::MoveViewportTo()` line 1722):**
```cpp
if (center && mwinh < viewport.h) {
    p.y += mwinh / 2;  // center NPC in visible strip
    core->timer.SetMoveViewPort(p, speed, center);
} else if (center) {
    // fullscreen window — skip pan entirely
    updateVPTimer = false;
    return canMove;
} else {
    core->timer.SetMoveViewPort(p, speed, center);
}
```

**Patch:** `patches/CORE_fixes.patch` (now 4 hunks: viewport centering, GameControl.h include, buttonStates guard, InDialog guard)

---

## 16. Build System — Custom Script Overlay

**Problem:** Every engine rebuild (`build.sh`) replaces `engine/GUIScripts/pst/` with fresh upstream Python scripts, wiping our custom `MessageWindow.py` and `FloatMenuWindow.py`. These are full file replacements (not diffable patches) so a C++ patch approach doesn't apply.

**Fix:** Added `custom_scripts/pst/` directory to the project. The build script mounts it read-only into Docker and copies the files over the upstream versions right before packaging the zip:

```
-v "$SCRIPT_DIR/custom_scripts:/workspace/custom_scripts:ro"
```
```bash
cp /workspace/custom_scripts/pst/*.py /workspace/gemrb/build/engine/engine/GUIScripts/pst/
```

**Files:**
- `custom_scripts/pst/MessageWindow.py` — dialogue layout overhaul + OnClose safety net
- `custom_scripts/pst/FloatMenuWindow.py` — null-on-close crash fix
- `build.sh` — added volume mount + copy step

**To add more custom scripts:** drop them in `custom_scripts/pst/` — next build picks them up automatically.

---

## 15. Block Esc During Dialogue (C++ + Python)

**Problem:** Our custom `MessageWindow.py` clears `IE_GUI_VIEW_IGNORE_EVENTS` on MWindow during dialogue to enable keyboard scrolling (entry #9). In upstream, that flag is never cleared — it stays set permanently, so `Window::OnKeyPress` returns early at the `IgnoreEvents` check and Esc never reaches `Close()`. By clearing the flag for scroll support, we inadvertently allowed Esc (B button via gptokeyb) to close the dialogue window mid-conversation — hiding all UI and leaving the game stuck.

**Fix (two layers):**

**C++ — `CORE_fixes.patch` (Window.cpp `OnKeyPress`):** Before calling `Close()`, check `GameControl::InDialog()`:
```cpp
if (key.keycode == GEM_ESCAPE && mod == 0) {
    const GameControl* gc = core->GetGameControl();
    if (gc && gc->InDialog()) {
        return true; // swallow Esc, don't close
    }
    Close();
    return true;
}
```
`GameControl::InDialog()` returns `DialogueFlags & DF_IN_DIALOG` — the proper upstream API for checking dialogue state.

**Python — `MessageWindow.py` (safety net):** `MWindow.OnClose(OnDialogWindowClose)` restores NOT_DLG windows (portrait/action/options bars) if MWindow somehow closes during dialogue through any unanticipated path.

**Patch:** `patches/CORE_fixes.patch` (3 hunks: GameControl.h include, buttonStates guard, InDialog guard)

---

## 13. Dialogue Customization Patch — Expose UI Controls to Python

**Problem:** Four things were hardcoded in C++ with no Python access, blocking full dialogue UI customization on the handheld:
1. TextArea margins — `SetMargins()` existed in C++ but had no Python binding
2. Dialogue option margins — hardcoded `Margin(LineHeight(), 40, 10)` wasted 80px horizontal space
3. Speaker name format — `"Name - [p]text[/p]"` confined text to remaining width after name
4. Option number prefix — `"1. - "` wasted ~20px per line
5. Scrollbar — attached at CHU load, no Python access to hide/resize it

**Fix (C++ patch, 6 files):**

| File | Change |
|------|--------|
| `GUIScript.cpp` | New `TextArea_SetMargins(top,right,bottom,left)` + `TextArea_GetScrollBar()` Python bindings |
| `GUIClasses.py` | Added `SetMargins` + `GetScrollBar` to `GTextArea.methods` |
| `TextArea.cpp` | Option margins respect `textMargins` if set; compact prefix `"1."` instead of `"1. - "`; `GetScrollBar()` impl |
| `TextArea.h` | Added `GetScrollBar()` declaration |
| `ScrollView.h` | Added `GetVScroll()` public getter (1 line) |
| `DisplayMessage.cpp` | Speaker name format `"Name:\n[p]text"` — name on own line, full-width text below |

**What's now Python-controllable (no recompile to tweak):**
- TextArea margins: `MessageTA.SetMargins(top, right, bottom, left)`
- Scrollbar: `MessageTA.GetScrollBar().SetVisible(False)` or `.SetFrame()` to resize
- Continue button (control 0): `GetControl(0).SetFrame()` / `.SetText()` — already worked
- Gold counter (control 0x10000003): `GetControl(0x10000003).SetFrame()` — already worked

**Patch:** `patches/dialogue_customization.patch`

---

## 14. Dialogue Window Layout Overhaul (Python)

**Problem:** Stock CHU window 7 is 640x192 (bottom 40%) with a MOS bitmap background that can't resize. On the handheld, text is tiny (BAM 14px), options are red-on-blue (low contrast), and the portrait/action bars overlap when the window is enlarged.

**CHU control positions (debug dump):**
```
MWindow:    x=0   y=288  w=640  h=192
TextArea:   x=63  y=13   w=502  h=168
CloseBtn:   x=568 y=118  w=64   h=64
GoldLabel:  x=577 y=42   w=46   h=21
ScrollBar:  x=484 y=4    w=0    h=156
```

**Fix (MessageWindow.py, Python-only):**
- Window: 640x288 (60% height) with dark semi-transparent fill (`SetBackground({'r':0,'g':0,'b':0,'a':144})`)
- TextArea: near full-width (632px), custom margins via `SetMargins(4,16,4,16)`
- Close/Continue button: reshaped from 64x64 corner to 640x28 full-width bar at bottom
- Gold counter: moved to compact 56x18 top-right
- Scrollbar: repositioned via `GetScrollBar().SetFrame()` (8px wide, right-aligned)
- Colors: light grey NPC text, soft blue options, warm yellow hover on dark background
- Hide NOT_DLG windows (portrait bar, action bar, options bar) during dialogue via `IE_GUI_VIEW_INVISIBLE` flag — fixes z-index overlap
- Re-enable keyboard scrolling: clear `IE_GUI_VIEW_IGNORE_EVENTS`, focus TextArea

**Font override (fonts.2da):**
- Dialogue font switched from BAM `FONTDLG` 14px to TTF `Literata` 18px
- Rows 0 and 8 both pointed to Literata (both share RESREF `FONTDLG`, row 8 overwrites row 0)
- `Literata.ttf` placed in `games/pst/override/` (not `fonts/` — FAT32 `DirectoryIterator` bug causes `CustomFontPath` to report "Empty directory")
- **Gotcha:** `fonts.2da` must exist in BOTH `games/pst/override/` (takes priority in GemRB resource lookup) AND `engine/unhardcoded/pst/` — the override copy wins, so editing only the engine copy has no effect

**Files on device:**
- `/mnt/mmc/ports/gemrb/engine/GUIScripts/pst/MessageWindow.py`
- `/mnt/mmc/ports/gemrb/engine/unhardcoded/pst/fonts.2da`
- `/mnt/mmc/ports/gemrb/games/pst/override/Literata.ttf`

---

## 12. Switch to gptokeyb for Controls

**Problem:** Master's `USE_SDL_CONTROLLER_API=ON` provides native GamepadControl with analog stick cursor, dead zones, and DPad soft keyboard. But TrimUI Brick has no analog sticks — no cursor movement at all. Button mappings are hardcoded in C++ with no config-file remapping.

**Fix:** Set `USE_SDL_CONTROLLER_API=OFF` in CMake. Re-enabled gptokeyb in launch script (`GemRB.sh`). All input goes through gptokeyb translating D-pad to mouse and buttons to keyboard, configured via `gemrb.gptk`.

**Files:**
- `build.sh` — `-DUSE_SDL_CONTROLLER_API="OFF"`
- `/mnt/mmc/ROMS/Ports/GemRB.sh` — uncommented `$GPTOKEYB "gemrb" -c "${GPTOKEYB_CFG}" textinput &`
- `/mnt/mmc/ports/gemrb/gemrb.gptk` — `dpad_mouse_step=10` (2x default of 5), `mouse_delay=16`. Note: `mouse_scale` only affects analog sticks, not D-pad.

---

## 11. GemRB Master Upgrade — OnMouseDrag Crash Fix

**Problem:** GemRB master crashes on launch with `assert(me.buttonStates)` at `Window.cpp:676`. Mouse motion events (from gptokeyb D-pad→mouse translation) call `OnMouseDrag` in the `MouseMove` case of `Window::DispatchEvent`, but `OnMouseDrag` asserts that a mouse button is held. Any cursor movement without a button pressed triggers the crash.

**File:** `Window.cpp:589` (in `DispatchEvent`, case `Event::MouseMove`)

**Fix:** Guard `OnMouseDrag` with a `buttonStates` check — only call it when a button is actually pressed:
```cpp
if (target == this) {
    if (event.mouse.buttonStates) {
        OnMouseDrag(event.mouse);
    }
}
```

**Patch:** `patches/CORE_fixes.patch`

---

# Phase 2: GemRB v0.9.4 + Custom GLES2 Renderer (archived)

> **Note:** Phase 2 is historical. All changes below were superseded by Phase 3 (upstream master). Kept for reference — the GLES2 shader approach developed here carried forward into Phase 3.

Rebuilt from upstream v0.9.4. Uses system SDL2 2.30. All rendering goes through a custom GLES2 shader program with direct GL draws — no more SDL2 shader hijacking or bundled SDL2. Superseded by Phase 3 (master) but kept for reference.

Build: `gemrb-fix/build_gemrb_094.sh` → `engine_094_vanilla.zip`
Patches: `gemrb-fix/patches_094/` (CORE_fixes, GLES2_fixes, GLES2_shader_fix)

---

## 10. GemRB v0.9.4 Upgrade — GLES2 Rendering Overhaul

**Problem:** GemRB v0.9.2 (previous) had limited GLES2 support. Upgrading to v0.9.4 introduced a fundamentally new shader pipeline that required significant fixes to work on the PowerVR GE8300 GLES2 renderer.

**Build:** `gemrb-fix/build_gemrb_094.sh` — applies three patches from `patches_094/` to upstream v0.9.4, cross-compiles via PortMaster Docker image.

---

# Phase 1: GemRB v0.9.2 + Bundled SDL2 2.26.5 (archived)

> **Note:** Phase 1 is historical. The bundled SDL2 approach was replaced by a custom GLES2 shader in Phase 2, then refined in Phase 3. Kept for reference.

Used GemRB v0.9.2 with a bundled older SDL2 to work around GLES2 compositor bugs. Superseded by Phase 2 but kept for reference.

---

## 1. Bundle SDL2 2.26.5 — Fix Black Circles Around Characters

**Problem:** MuOS ships SDL2 2.30 system-wide. It has a broken `SDL_ComposeCustomBlendMode` fallback for fog of war on GLES2, causing black circles around all characters in GemRB. SDL2 2.26 doesn't have this bug.

**Solution:** Bundle SDL2 2.26.5 (from JohnnyonFlame's `release-2.26.5` branch with PVR GE8300 mali-fbdev patches) in GemRB's `lib/` directory. The launch script sets `LD_LIBRARY_PATH` to pick it up instead of the system SDL2.

**Build:** `gemrb-fix/build_sdl2.sh` — uses PortMaster Docker image (`ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest`)

**Output:** `libSDL2-2.0.so.0.2600.5` (1.7MB aarch64) deployed as `/mnt/mmc/ports/gemrb/lib/libSDL2-2.0.so.0`

**Note:** A GLES2 shader fix (`GLES2_shader_fix.patch`) was attempted first but FAILED — it caused rendering corruption (flipped, blinking, black). The shader hijack approach was fundamentally fragile. Bundling SDL2 2.26 was the working solution.

---

## 2. Screen Offset Fix in SDL2 mali-fbdev Driver

**Problem:** The original PVR GE8300 patch hardcoded window size to 1280x720 and passed NULL to `eglCreateWindowSurface`. EGL created a surface at unknown default size, causing viewport mismatch — content shifted to bottom-right with black bars.

**Files:**
- `sdl2-2.26.5-mali/src/video/mali-fbdev/SDL_malivideo.c` — Read actual fb0 dimensions (`vinfo.xres/yres`), store in `SDL_DisplayData.fb_width/fb_height`, use for `window->w/h`
- `sdl2-2.26.5-mali/src/video/mali-fbdev/SDL_malivideo.h` — Added `fb_width`/`fb_height` fields to `SDL_DisplayData`

**Key lesson:** PVR GE8300 EGL crashes if you pass `&struct` (pointer to fbdev_window struct). Must pass `native_display` by VALUE to `eglCreateWindowSurface`.

---

## 3. Controller CRC Fix in SDL2

**Problem:** SDL2 2.26 computes GUID CRC from prettified name ("Xbox 360 Controller" via `GuessControllerName`), while 2.30 computes from raw `EVIOCGNAME` ("TRIMUI Brick Controller"). TrimUI Brick reports Xbox 360 vendor/product IDs (0x045e/0x028e), so the CRC mismatch caused the TrimUI mapping to not be found.

**File:** `sdl2-2.26.5-mali/src/joystick/linux/SDL_sysjoystick.c:239`

**Fix:** Changed `name` to `product_string` in `SDL_CreateJoystickGUID()` call, matching SDL2 2.30 behavior.

---

## 4. TrimUI Brick Controller Mapping in SDL2

**Problem:** System `gamecontrollerdb.txt` has wrong button numbers for TrimUI Brick (a:b5,b:b4 — actual hardware sends a:b1,b:b0). Also SDL2 2.26 vs 2.30 assign different indices for Select/Start/Menu/LED buttons (b8-b12 in 2.26, b12-b16 in 2.30).

**File:** `sdl2-2.26.5-mali/src/joystick/SDL_gamecontroller.c`

**Fix:** Hardcoded correct mapping at USER priority after `SDL_GameControllerLoadHints()`:
```
a:b1,b:b0,x:b3,y:b2,back:b8,guide:b10,start:b9,
leftshoulder:b4,rightshoulder:b5,lefttrigger:b6,righttrigger:b7,
leftstick:b11,rightstick:b12,dpleft:h0.8,dpdown:h0.4,dpright:h0.2,dpup:h0.1
```

**Discovery method:** Built a C button test tool (`button_test.c`) that logs raw joystick events and SDL controller events, cross-compiled for aarch64 and ran on device to identify actual button codes.

---

## 5. FloatMenuWindow Crash Fix

**Problem:** GemRB crashes when pressing Esc — assertion `target->IsVisible()` in `Window::DispatchEvent`. Root cause: PST's `FloatMenuWindow.py` never nulls the global `FloatMenuWindow` after the radial menu window closes. `GUICommonWindows.py:1403` then calls `.Close()` on a stale reference → `AttributeError: Invalid view` (logged 5 times before crash) → internal window state corruption → assertion failure.

**File:** `/mnt/mmc/ports/gemrb/engine/GUIScripts/pst/FloatMenuWindow.py`

**Fix:** Added `global FloatMenuWindow` + `FloatMenuWindow = None` at top of `OnClose()` nested function inside `OpenFloatMenuWindow()`. Python-only fix, no recompile.

**Backup:** `gemrb-fix/FloatMenuWindow.py.patched`

---

## 6. Font Override — LiberationSerif TTF

**Problem:** Default PST bitmap fonts (BAM) are too small at 640x480 on a handheld screen. BAM fonts completely ignore the `PX_SIZE` setting in `fonts.2da` — the BAMFontManager code literally comments out the `ptSize` parameter.

**Solution:** Switch dialogue font from BAM to TTF. When `FONT_NAME` in `fonts.2da` doesn't match a `.bam` file, GemRB falls through to the TTFImporter which respects `PX_SIZE`.

**Files on device:**
- `/mnt/mmc/ports/gemrb/games/pst/override/LiberationSerif-Regular.ttf` — Copied from `/usr/share/fonts/liberation/` on device
- `/mnt/mmc/ports/gemrb/games/pst/override/fonts.2da` — Rows 0 and 8 use TTF at 18px

**Gotcha:** Rows 0 and 8 share the same RESREF (`FONTDLG`). Row 8 loads after row 0 and overwrites it. BOTH rows must use the TTF, otherwise row 8's BAM overwrites row 0's TTF. Row 9 (`NORMAL`) must exist — removing it crashes the load screen (`TextArea.cpp:236: Assertion 'ftext && finit' failed`).

---

## 7. Input Controls — gptokeyb Mapping

**File on device:** `/mnt/mmc/ports/gemrb/gemrb.gptk`

| Button | Action | Value |
|--------|--------|-------|
| D-pad | Mouse cursor | `mouse_movement_*` |
| A | Left click | `mouse_left` |
| B | Escape (back/dismiss) | `esc` |
| X | Center character | `c` |
| Y | Right click (radial menu) | `mouse_right` |
| L1 | Scroll up | `up` |
| L2 | Scroll down | `down` |
| R1 | Highlight objects | `tab` |
| R2 | Wizard spells | `w` |
| Start | Pause | `space` |
| Select | Quick save | `q` |
| Menu | Options | `o` |
| Left LED | Inventory | `i` |
| Right LED | Map | `m` |

Mouse speed: `dpad_mouse_step=10`, `mouse_delay=16` (~625 px/sec). Note: `mouse_scale` only affects analog sticks (irrelevant — TrimUI Brick has none). `dpad_mouse_step` is the actual D-pad cursor speed in pixels per tick.

**gptokeyb naming gotchas:** Uses `l3`/`r3` (not `leftstick`/`rightstick`), `esc` (not `escape`), `back` (not `select`).

---

## 8. Taller Dialogue Window

**Problem:** The CHU-defined dialogue window (window 7) is too small for comfortable reading on a handheld screen, especially with the larger TTF font. Naively resizing with `SetFrame()` doesn't work because the background is a fixed-size MOS bitmap from the CHU file — text overflows past the visual border.

**File:** `/mnt/mmc/ports/gemrb/engine/GUIScripts/pst/MessageWindow.py`

**Fix:** Replace the fixed MOS bitmap background with a solid semi-transparent color fill using `SetBackground({'r':0,'g':0,'b':0,'a':200})`, then enlarge the window by 160px with `SetFrame()`. The TextArea inside has `IE_GUI_VIEW_RESIZE_ALL` flag set, so it (and its internal ScrollView + scrollbar) auto-resize via the `ResizeSubviews` chain when the parent window frame changes. Only the window needs explicit resizing.

**Code added at end of `OnLoad()`, before `UpdateControlStatus()`:**
```python
extra_h = 160
mframe = MWindow.GetFrame()
mframe['h'] += extra_h
mframe['y'] -= extra_h
MWindow.SetFrame(mframe)
MWindow.SetBackground({'r': 0, 'g': 0, 'b': 0, 'a': 200})
```

**Key lessons:**
- `SetFrame()` alone just repositions — the MOS background stays its original size
- Resizing both window and TextArea explicitly causes text overflow glitches
- `SetBackground()` with a color dict replaces the MOS with a scalable solid fill
- The TextArea's `IE_GUI_VIEW_RESIZE_ALL` flag handles child resizing automatically

---

## 9. Keyboard Scrolling in Dialogue

**Problem:** L1/L2 mapped to arrow up/down via gptokeyb, but pressing them scrolls the game viewport instead of the dialogue text.

**Root cause:** MWindow has `IE_GUI_VIEW_IGNORE_EVENTS` flag set at creation (MessageWindow.py:60). When key events arrive, `GetFocusWindow()` (WindowManager.cpp:320) skips windows with this flag → falls through to `gameWin` (GameControl) → `GameControl::OnKeyPress` consumes arrow keys for viewport scrolling (GameControl.cpp:680-695). The scrolling code already exists in `ScrollView::OnKeyPress()` (ScrollView.cpp:349-374) — the events just never reach it.

**File:** `/mnt/mmc/ports/gemrb/engine/GUIScripts/pst/MessageWindow.py`

**Fix:** In `UpdateControlStatus()`, when entering dialogue mode: clear `IE_GUI_VIEW_IGNORE_EVENTS` so the window becomes the focus target for key events, then focus the TextArea so arrow keys route through its `eventProxy` to the internal ScrollView. On dialogue close, restore the flag.

```python
def UpdateControlStatus ():
	if GemRB.GetGUIFlags() & (GS_DIALOGMASK|GS_DIALOG):
		Label = MWindow.GetControl (0x10000003)
		Label.SetText (str (GemRB.GameGetPartyGold ()))

		MWindow.SetFlags(IE_GUI_VIEW_IGNORE_EVENTS, OP_NAND)
		MWindow.Focus()
		MessageTA = MWindow.GetControl (1)
		MessageTA.Focus()
	elif MWindow:
		MWindow.SetFlags(IE_GUI_VIEW_IGNORE_EVENTS, OP_OR)
		MWindow.Close()
```

**Known issue:** Scroll speed is very slow — `ScrollView::OnKeyPress()` uses a hardcoded `int amount = 10` (10px per keypress). The gameplay menu "Keyboard Scroll Speed" setting only affects `GameControl` viewport scrolling (GameControl.cpp:686), not `ScrollView`. Needs C++ fix to increase.

---

### 10a. Separate GL Program (Fix Black Screen)

**Problem:** Original GemRB hijacked SDL2's internal GLES2 shader program by intercepting `GL_CURRENT_PROGRAM` after a dummy `SDL_RenderCopy`. This corrupted SDL2's internal program cache — uniform locations became stale, causing total black screen.

**Fix (SDL20Video.cpp):** Create a brand-new GL program via `GLSLProgram::CreateFromFiles(..., 0)` instead of passing the hijacked program ID. SDL2's own ABGR shader remains untouched for compositing in `SwapBuffers`.

### 10b. Direct GL Draws (Fix Missing Sprites)

**Problem:** SDL2's `SDL_RenderCopyEx` uses its own internal shader, not ours. Our custom shader (with greyscale, stencil, channel swap) was never applied.

**Fix (SDL20Video.cpp `RenderCopyShaded`):** Bypass `SDL_RenderCopyEx` entirely with direct GL draws:
- Build a 6-vertex quad (2 triangles) with position, color, and texcoord attributes
- Bind sprite texture via `SDL_GL_BindTexture` to get the underlying GL handle
- Handle all blend modes (ADD, MOD, MUL, SRC, DST, ONE_MINUS_DST, BLENDED) via `glBlendFuncSeparate`
- Handle MIRRORX/MIRRORY via texcoord swap

### 10c. GL State Save/Restore (Fix Subsequent SDL2 Draws)

**Problem:** SDL2 tracks GL state internally and skips redundant calls. If our direct draws change GL state without restoring it, SDL2's tracking goes stale — it won't re-bind its own program/blend/textures.

**Fix (SDL20Video.cpp):** Full GL state save/restore around our draws:
- `GL_CURRENT_PROGRAM` — our shader vs SDL2's shader
- `GL_BLEND` + blend functions (src/dst RGB/A)
- `GL_ACTIVE_TEXTURE` + `GL_TEXTURE_BINDING_2D` on unit 0
- `GL_ARRAY_BUFFER_BINDING` — unbind VBO for client-side vertex arrays, restore after
- `GL_VIEWPORT` — save/restore around our explicit viewport set
- `GL_SCISSOR_TEST` — disable during our draws, restore after

### 10d. GLES2 Vertex Shader + Attribute Bindings

**Problem:** Desktop GL uses `gl_Vertex`, `gl_Color`, `gl_MultiTexCoord0`, `gl_ModelViewProjectionMatrix` — none of which exist in GLES2.

**Fix:**
- `SDLTextureV.glsl`: Added `#ifdef USE_GLES` path with explicit attributes (`a_position`, `a_color`, `a_texCoord`) and `u_projection` uniform matrix
- `GLSLProgram.cpp`: Prepend `#define USE_GLES 1` to shader source on GLES2; bind attribute locations (0/1/2) before linking to match SDL2's GLES2 renderer convention
- `BlitRGBA.glsl`: Wrap `u_brightness`/`u_contrast` in `#ifndef USE_GLES` — these are desktop-only and cause link errors on GLES2

### 10e. Fix Blue Tint (R↔B Channel Swap)

**Problem:** SDL2 GLES2 renderer uploads ALL textures as `GL_RGBA` regardless of SDL pixel format. For `ARGB8888` textures on little-endian ARM, memory layout is `[B,G,R,A]` — GL reads `r=B, g=G, b=R, a=A`, swapping red and blue. SDL2's own shaders fix this internally, but our custom shader bypassed them.

**Fix:**
- `BlitRGBA.glsl`: Added `uniform int u_swapRB`. When set, `texel.rb = texel.br` after texture sample
- `SDL20Video.cpp`: Query texture format via `SDL_QueryTexture`. Set `u_swapRB=1` for `SDL_PIXELFORMAT_ARGB8888` and `SDL_PIXELFORMAT_BGRA8888`

### 10f. Fix Viewport/Projection (Mispositioned Sprites)

**Problem:** SDL2 defers `glViewport` calls — they only fire inside `SetDrawState` during SDL draw commands. Our direct GL draws bypass SDL's draw commands, so `glViewport` was never called, leaving a stale viewport from a previous render target. This caused the projection matrix to use wrong dimensions.

**Fix (SDL20Video.cpp):** Use `SDL_RenderGetViewport` + `SDL_RenderGetScale` to compute viewport and projection, matching what SDL2's GLES2 renderer does internally in `SetDrawState`:
- Projection uses logical viewport dimensions (accounts for `SDL_RenderSetLogicalSize`)
- Physical GL viewport computed from logical viewport × scale factor
- For FBO targets: `glViewport(x*scale, y*scale, w*scale, h*scale)` (typically scale=1.0)
- For screen: Y-flipped for GL convention (`physY = outH - logicalY*scale - physH`)

### Patch file

All above changes are in `patches_094/GLES2_shader_fix.patch`, applied by `build_gemrb_094.sh`. Modified files:
- `gemrb/plugins/SDLVideo/SDL20Video.cpp`
- `gemrb/plugins/SDLVideo/GLSLProgram.cpp`
- `gemrb/plugins/SDLVideo/Shaders/BlitRGBA.glsl`
- `gemrb/plugins/SDLVideo/Shaders/SDLTextureV.glsl`

---

## File Locations

### On device (`/mnt/mmc/ports/gemrb/`)
| Path | Description |
|------|-------------|
| `engine/` | GemRB master engine (from `engine.zip`) |
| `engine/Shaders/` | BlitRGBA.glsl, SDLTextureV.glsl (custom GLES2 shaders) |
| `engine/plugins/` | SDLVideo.so, GUIScript.so, etc. |
| `engine/GUIScripts/pst/FloatMenuWindow.py` | Crash fix — null stale reference |
| `engine/GUIScripts/pst/MessageWindow.py` | Full-width dialogue layout + z-index fix + keyboard scrolling |
| `engine/unhardcoded/pst/fonts.2da` | TTF font override (Literata 18px) |
| `games/pst/override/Literata.ttf` | TTF font file (serif, readable on handheld) |
| `games/pst/override/LiberationSerif-Regular.ttf` | Alternate TTF font (unused, kept as fallback) |
| `gemrb.gptk` | Button mapping for gptokeyb (dpad_mouse_step=10) |

### Repository (`~/gemrb-brick/`)
| Path | Description |
|------|-------------|
| `build.sh` | Cross-compile script (PortMaster Docker) |
| `deploy.sh` | Deploy to device via adb (with backup/rollback) |
| `patches/` | 5 patches: CORE_fixes, GLES2_fixes, GLES2_shader_fix, dialogue_customization, video_fix |
| `custom_scripts/pst/` | Python UI overrides: MessageWindow, FloatMenuWindow, PortraitWindow, Container, GUIJRNL |
| `device/` | Device configs: gemrb.gptk, fonts.2da, Literata.ttf, gemrb.ini |
| `engine.zip` | Latest build output (.gitignored) |
| `upstream-gemrb/` | Upstream GemRB clone (.gitignored) |

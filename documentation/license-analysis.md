# License & Redistribution Analysis

## Executive Summary

**YES — we can redistribute the Luanti engine, VoxeLibre, and all key mods, modified or unmodified, for non-commercial use.** In fact, every component's license *already permits commercial redistribution too*. There are no NonCommercial clauses anywhere in the stack.

The obligations are: **attribution, share-alike (copyleft), and source availability** — all trivially satisfied for a Lua-based game where "source" is the shipped scripts.

---

## Component License Matrix

Sourced from content.luanti.org (authoritative metadata):

| Component | Code License | Media License | Commercial OK? |
|-----------|-------------|---------------|----------------|
| **Luanti Engine** | Mixed (LGPL/MIT per-file) | CC-BY-SA 3.0/4.0 | ✅ Yes |
| **VoxeLibre** (MC clone game) | **GPL-3.0-or-later** | CC-BY-SA-4.0 | ✅ Yes |
| **Technic** (tech/electricity) | LGPL-2.1-only | LGPL-2.1-only | ✅ Yes |
| **Mesecons** (redstone equiv) | LGPL-3.0-only | LGPL-3.0-only | ✅ Yes |
| **Pipeworks** (item transport) | LGPL-3.0-only | CC-BY-SA-4.0 | ✅ Yes |
| **Digtron** (tunnel borer) | **MIT** | MIT | ✅ Yes |
| **LWComputers** (programming) | LGPL-2.1-or-later | CC-BY-SA-4.0 | ✅ Yes* |
| **mt-multiserver-proxy** | (check Go source) | — | — |

*⚠️ LWComputers has been moved to `mt-historical/lwcomputers` — it's effectively archived/unmaintained. We may need to fork and maintain it ourselves, or build our own computer system.

---

## What Each License Requires

### GPL-3.0-or-later (VoxeLibre — the only "strong copyleft" one)
- ✅ Redistribute freely, modified or not, commercial or not
- ⚠️ **Copyleft**: Your modifications to VoxeLibre must also be GPL-3.0+
- ⚠️ Provide source code of modified VoxeLibre (trivial — it's Lua, shipping source = shipping the game)
- ⚠️ Mark changes as changed
- "or-later": recipients can apply GPL-3 or any future version (GPL-4, etc.)

**Impact on us:** If we modify VoxeLibre itself (e.g., tweak its worldgen, add blocks), those modifications are GPL-3.0+. Anyone can take our modified VoxeLibre and use it. For a non-commercial project, this is perfectly aligned with the ecosystem's spirit.

### LGPL-2.1 / LGPL-3.0 (Technic, Mesecons, Pipeworks, LWComputers)
- ✅ Redistribute and modify freely
- ✅ **Less restrictive than GPL**: can be used in projects of any license
- ⚠️ Modified LGPL components must stay LGPL + provide source
- ⚠️ Users must be able to replace the LGPL component (in Luanti: trivial — they swap the mod folder)

**Impact on us:** We can modify these mods freely and bundle them. Our own code doesn't "catch" LGPL as long as we keep it separate. Since Luanti mods are independent Lua scripts, this separation is natural.

### MIT (Digtron)
- ✅ Most permissive. Modify, bundle, relicense, do anything.
- ⚠️ Just keep the copyright notice.

### CC-BY-SA-4.0 (media/textures/sounds)
- ✅ Redistribute and modify
- ⚠️ Attribution required
- ⚠️ **Share-alike**: derivative media must be CC-BY-SA-4.0 (or compatible, e.g. GPLv3)
- ✅ Commercial use allowed

---

## Our Obligations (The Checklist)

To legally redistribute this game:

| Obligation | How We Satisfy It | Effort |
|-----------|-------------------|--------|
| **Attribution** | Maintain `CREDITS.md` crediting VoxeLibre, Technic, Mesecons, etc. | Low |
| **Source availability** | Ship all `.lua` files (we do anyway — it's a Lua game) | Zero |
| **Copyleft on GPL mods** | License our VoxeLibre modifications as GPL-3.0+ | Low |
| **Copyleft on LGPL mods** | License our Technic/Mesecons modifications as LGPL | Low |
| **Share-alike on media** | License derivative textures as CC-BY-SA-4.0 | Low |
| **Mark changes** | Note modifications in each mod's README | Low |
| **Provide LICENSE files** | Keep original LICENSE.txt in each mod folder | Zero |

**None of this is burdensome.** It's all standard open-source hygiene.

---

## Our Own Code: What License?

Our Stargate mod, energy system, dimension framework, etc. are **new works**. We choose their license:

### Option A: License everything GPL-3.0+ (Simplest)
- Fully compatible with VoxeLibre (also GPL-3.0+)
- No ambiguity about "linking" or "derivative works"
- Aligns with the Luanti ecosystem norms
- Anyone can fork/redistribute our game (which they could anyway since we're non-commercial)

### Option B: Mixed licensing (More control)
- Our standalone mods (Stargate, energy, data crystals): **MIT or LGPL**
- Our modifications to VoxeLibre: **GPL-3.0+** (required)
- Cleaner separation of "our IP" vs "modified community code"
- Slightly more bookkeeping

**Recommendation: Option A (GPL-3.0+ for everything).** For a non-commercial project, the copyleft is a feature, not a burden. It guarantees the game stays free and open. We're not trying to protect commercial IP — we're building on a gift economy.

---

## ⚠️ The Stargate IP Question (Important)

This is a separate legal issue from the licenses above:

**"Stargate," "Atlantis," "Abydos," "Chulak," "ZPM," "Naquadah," "DHD," etc. are trademarks and copyrighted elements of the Stargate franchise, owned by MGM.**

Using these names in a game is a trademark/copyright gray area:

| | Risk Level | Reality |
|---|---|---|
| **Non-commercial fan project** | Low-Medium | Typically tolerated by IP holders. MGM hasn't pursued Stargate fan games aggressively. But no legal guarantee. |
| **Using franchise names** | Medium | "Stargate," "Atlantis" are recognizable marks. |
| **Using franchise mechanics** | Low | Game mechanics aren't copyrightable. Portals + dialing + symbols are fine. |
| **Using franchise lore/characters** | Higher | Named planets, specific lore references risk trademark issues. |

### Mitigation Options
1. **Use original names** — safest. Our gates are "Astral Gates," Atlantis is "The Sunken City," ZPMs are "Zero-Point Cores," etc. Same mechanics, original branding.
2. **Keep franchise names, mark as fan work** — riskier but more thematically resonant. Add clear "Unofficial fan project, not affiliated with MGM" disclaimers.
3. **Hybrid** — original names with subtle nods (a planet called "Abydos" that's clearly inspired but not claiming to *be* the Stargate Abydos).

**This is a decision for the user, not a technical one.** The Luanti/mod licenses don't constrain this at all — it's purely about MGM's IP.

---

## The Minecraft Resemblance Question

VoxeLibre is "inspired by Minecraft, pushing beyond" and has been distributed for years without Mojang/Microsoft action. This is legally sound because:

- **Game mechanics are not copyrightable** (the rules of survival crafting sandbox)
- **VoxeLibre's textures are NOT Minecraft's textures** — they're from the third-party "Pixel Perfection" resource pack (CC-BY-SA-4.0 by XSSheep)
- **VoxeLibre's code is original** — written from scratch, not decompiled from Minecraft

**Our obligation:** Don't reproduce actual Minecraft assets (textures, sounds, models). Use VoxeLibre's CC-licensed media or create our own. We're already on the right side of this by using VoxeLibre as our base.

---

## Conclusion

**The licenses are not an obstacle.** Every component can be redistributed, modified, and bundled for non-commercial use — and even for commercial use if we wanted (we don't).

Our only real obligations:
1. **Credit the original authors** (CREDITS.md)
2. **Keep modifications under compatible licenses** (GPL-3.0+ for VoxeLibre-derived code)
3. **Decide our Stargate IP stance** (original names vs. fan-project names)

The path is legally clear. The architectural decision (Luanti + VoxeLibre + multi-server model) is viable from both technical and legal standpoints.

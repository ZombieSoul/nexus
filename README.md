# Minecraft Modpack

## Overview
Custom Minecraft modpack combining existing community mods with custom-built mods to fill gaps.

## Project Structure
```
├── config/              # Mod configuration files
├── mods/                # Existing mod jars (not tracked in git)
├── resourcepacks/       # Custom resource packs
├── scripts/             # CraftTweaker / other scripts
├── kubejs/              # KubeJS scripts & assets
│   ├── server_scripts/  # Server-side recipes, loot tables, etc.
│   ├── client_scripts/  # Client-side JEI info, tooltips, etc.
│   ├── startup_scripts/ # Registration, custom items/blocks
│   └── assets/          # KubeJS textures, models, lang files
├── custom-mods/         # Our custom Java/Kotlin mods
│   └── src/             # Source code for custom mods
└── documentation/       # Design docs, changelog, plans
```

## Modpack Details
- **MC Version:** (TBD)
- **Mod Loader:** (Forge / Fabric / NeoForge — TBD)
- **Theme:** (TBD)

## Workflow
1. **Existing Mods** → curated list in `mods/`, configured in `config/`
2. **Tweaks & Recipes** → KubeJS / CraftTweaker scripts
3. **Custom Mods** → built from `custom-mods/src/` to fill functionality gaps
4. **Assets** → textures, models, lang files in `kubejs/assets/` or `resourcepacks/`

## Notes
- `.gitignore` excludes mod jars — track only configs and source
- Custom mod builds go into `mods/` after compilation

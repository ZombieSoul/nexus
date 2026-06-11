#!/usr/bin/env python3
"""
Search CurseForge and Modrinth for Minecraft mods.
Usage:
    python modsearch.py <query>                    # search both platforms
    python modsearch.py <query> --source curseforge # CurseForge only
    python modsearch.py <query> --source modrinth   # Modrinth only
    python modsearch.py <query> --loader neoforge   # filter by loader
    python modsearch.py <query> --version 1.21.1    # filter by MC version
"""

import argparse
import json
import sys
import urllib.request
import urllib.parse
import urllib.error

# ── Modrinth API (no key required) ──────────────────────────────────────────
MODRINTH_SEARCH = "https://api.modrinth.com/v2/search"
MODRINTH_PROJECT = "https://api.modrinth.com/v2/project/{}"

# ── CurseForge API (requires key via env var CURSEFORGE_API_KEY) ─────────────
CURSEFORGE_SEARCH = "https://api.curseforge.com/v1/mods/search"
CURSEFORGE_HEADERS_TEMPLATE = "x-api-key: {}"


def search_modrinth(query, game_version="1.21.1", loader="neoforge", limit=10):
    params = {
        "query": query,
        "facets": json.dumps([
            [f"versions:{game_version}"] if game_version else [],
            [f"categories:{loader}"] if loader else [],
            ["project_type:mod"],
        ]),
        "limit": limit,
        "index": "relevance",
    }
    url = f"{MODRINTH_SEARCH}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": "minecraft-modpack-tool/1.0"})
    
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        return {"error": str(e), "results": []}
    
    results = []
    for hit in data.get("hits", []):
        results.append({
            "platform": "Modrinth",
            "slug": hit.get("slug", ""),
            "name": hit.get("title", ""),
            "description": hit.get("description", "")[:200],
            "downloads": hit.get("downloads", 0),
            "followers": hit.get("follows", 0),
            "license": (hit.get("license", "") if isinstance(hit.get("license"), str) else hit.get("license", {}).get("name", "N/A")),
            "source": hit.get("source_url", ""),
            "link": f"https://modrinth.com/mod/{hit.get('slug', '')}",
            "client_side": hit.get("client_side", ""),
            "server_side": hit.get("server_side", ""),
            "open_source": bool(hit.get("source_url")),
        })
    return {"results": results}


def search_curseforge(query, game_version="1.21.1", loader="neoforge", limit=10):
    import os
    api_key = os.environ.get("CURSEFORGE_API_KEY", "")
    if not api_key:
        return {"error": "No CURSEFORGE_API_KEY env var set. Get one at https://console.curseforge.com", "results": []}
    
    # Game version ID mapping would need a separate API call; simplified here
    params = {
        "gameId": 432,  # Minecraft
        "searchFilter": query,
        "modLoaderType": 6 if loader == "neoforge" else 1,  # 6=NeoForge, 1=Forge
        "pageSize": limit,
        "sortField": 2,  # Popularity
    }
    url = f"{CURSEFORGE_SEARCH}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={
        "User-Agent": "minecraft-modpack-tool/1.0",
        "x-api-key": api_key,
        "Accept": "application/json",
    })
    
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        return {"error": str(e), "results": []}
    
    results = []
    for mod in data.get("data", []):
        results.append({
            "platform": "CurseForge",
            "slug": str(mod.get("id", "")),
            "name": mod.get("name", ""),
            "description": mod.get("summary", "")[:200],
            "downloads": mod.get("downloadCount", 0),
            "followers": 0,
            "license": "N/A",
            "source": "",
            "link": mod.get("links", {}).get("websiteUrl", ""),
        })
    return {"results": results}


def get_modrinth_versions(slug):
    """Get available versions for a specific mod."""
    url = f"https://api.modrinth.com/v2/project/{slug}/version"
    req = urllib.request.Request(url, headers={"User-Agent": "minecraft-modpack-tool/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        versions = []
        for v in data[:5]:
            versions.append({
                "version": v.get("version_number", ""),
                "game_versions": v.get("game_versions", []),
                "loaders": v.get("loaders", []),
                "date": v.get("date_published", ""),
                "downloads": v.get("downloads", 0),
            })
        return versions
    except Exception as e:
        return [{"error": str(e)}]


def format_number(n):
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}K"
    return str(n)


def print_results(results, verbose=False):
    if not results:
        print("  No results found.")
        return
    
    for i, r in enumerate(results, 1):
        print(f"\n  {i}. {r['name']}")
        print(f"     Platform: {r['platform']}  |  Downloads: {format_number(r['downloads'])}  |  Followers: {format_number(r['followers'])}")
        if r.get('client_side'):
            print(f"     Side: client={r['client_side']} server={r['server_side']}")
        if r.get('open_source') is not None:
            print(f"     Open Source: {'✓' if r.get('open_source') else '✗'}")
        print(f"     {r['description']}")
        print(f"     → {r['link']}")


def main():
    parser = argparse.ArgumentParser(description="Search Minecraft mods on Modrinth and CurseForge")
    parser.add_argument("query", help="Search query")
    parser.add_argument("--source", choices=["modrinth", "curseforge", "both"], default="both")
    parser.add_argument("--loader", default="neoforge", help="Mod loader filter (default: neoforge)")
    parser.add_argument("--version", default="1.21.1", help="MC version filter (default: 1.21.1)")
    parser.add_argument("--limit", type=int, default=10, help="Max results per platform")
    parser.add_argument("--versions", metavar="SLUG", help="Show versions for a specific Modrinth slug")
    parser.add_argument("--json", action="store_true", help="Output raw JSON")
    
    args = parser.parse_args()
    
    # Show versions for a specific mod
    if args.versions:
        versions = get_modrinth_versions(args.versions)
        if args.json:
            print(json.dumps(versions, indent=2))
        else:
            print(f"\nVersions for {args.versions}:")
            for v in versions:
                if "error" in v:
                    print(f"  Error: {v['error']}")
                else:
                    print(f"  {v['version']} | MC {', '.join(v['game_versions'])} | {', '.join(v['loaders'])} | {v['date'][:10]}")
        return
    
    if args.json:
        # JSON output
        all_results = []
        if args.source in ("modrinth", "both"):
            mr = search_modrinth(args.query, args.version, args.loader, args.limit)
            all_results.extend(mr.get("results", []))
        if args.source in ("curseforge", "both"):
            cf = search_curseforge(args.query, args.version, args.loader, args.limit)
            all_results.extend(cf.get("results", []))
        print(json.dumps(all_results, indent=2))
        return
    
    # Pretty output
    if args.source in ("modrinth", "both"):
        print(f"\n{'='*60}")
        print(f"  MODRINTH — \"{args.query}\" (MC {args.version}, {args.loader})")
        print(f"{'='*60}")
        mr = search_modrinth(args.query, args.version, args.loader, args.limit)
        if "error" in mr:
            print(f"  Error: {mr['error']}")
        else:
            print_results(mr["results"])
    
    if args.source in ("curseforge", "both"):
        print(f"\n{'='*60}")
        print(f"  CURSEFORGE — \"{args.query}\" (MC {args.version}, {args.loader})")
        print(f"{'='*60}")
        cf = search_curseforge(args.query, args.version, args.loader, args.limit)
        if "error" in cf:
            print(f"  Error: {cf['error']}")
        else:
            print_results(cf["results"])
    
    print()


if __name__ == "__main__":
    main()

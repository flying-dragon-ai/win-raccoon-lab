# Ideas backlog

- Parallelize per-entry measurement with a runspace pool; `scan_seconds` is
  dominated by serial robocopy spawns (~50 ms each).
- Cache measurement results keyed by (path, mtime) so repeat scans are instant.
- Add a `-Discover` mode: list the top-N largest unmapped directories under
  each allowed root, ranked by bytes, to drive map coverage systematically.
- Scan D: and E: for project build artifacts (`target/`, `build/`,
  `node_modules/`, `dist/`) — currently only C: is covered.
- Windows Store app caches: `%LOCALAPPDATA%\Packages\*\LocalCache`.
- Steam `steamapps\shadercache` lives under `%PROGRAMFILES(X86)%`, outside the
  current allowed roots — needs a root-allowlist extension plus a policy entry.
- Detect portable installs by process path (`Get-Process | ? Path -like ...`)
  so the "quit the app first" step can target the right binary.
- Emit a JSON Schema for `cache-map.jsonl` and validate against it.
- `-Clean` mode that moves entries into `.raccoon-trash` — deliberately out of
  scope for this loop (destructive), belongs in the skill workflow instead.

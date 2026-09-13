# Big-file demo note

Write ≥5 GB into a scanned path (`/Users`), then collect — this fires the
`user_growth` warning alert.

```bash
# 1. Create the file (~5-15s):
dd if=/dev/zero of="$HOME/demo-growth.bin" bs=1m count=6144

# 2. Click "Collect Now" in the menu-bar app (or: fsmetrics collect --once).
#    Within ~15s the alert appears:
#    "user '<you>' grew usage by ~6.44 GB in the last 600s on /"

# 3. Clean up:
rm "$HOME/demo-growth.bin"
```

Notes:

- Use `dd`, not `mkfile -n`: sparse files don't count as allocated space.
- The alert is a warning; capacity alerts would need ~90 GB to cross 80%.
- If a `user_growth` alert for the same user/volume fired within the last
  hour, the cooldown suppresses the new one. Clear alerts in the dashboard
  first if it doesn't appear.

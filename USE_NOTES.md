# Big-file demo note

Write ≥5 GB into a scanned path (`/Users`), then collect — this fires the
`user_growth` warning alert.

```bash
dd if=/dev/zero of="$HOME/demo-growth.bin" bs=1m count=6144

After:
```bash
rm "$HOME/demo-growth.bin"
```

#!/usr/bin/env bash
# Check the diagrams in a post.
#
#   check-mermaid.sh <post.md> <out_dir>         build <out_dir>/test.html: every <pre class="mermaid"> block and
#                                                <figure> SVG from the post, plus a script that renders each block and
#                                                sets window.results (one "ok" / "FAIL: ..." per block) and window.done.
#                                                Serve <out_dir> over http and open test.html in a browser.
#   check-mermaid.sh --cli <post.md>             render each block with mermaid-cli (downloads it via npx on first run);
#                                                exits non-zero on the first syntax error. Suitable for CI.
set -euo pipefail

extract_blocks() {  # $1 = post, $2 = dir to write block-NN.mmd into
  awk -v dir="$2" '
    /<pre class="mermaid">/ { n++; out = sprintf("%s/block-%02d.mmd", dir, n); inblock = 1; next }
    /<\/pre>/ && inblock    { inblock = 0; close(out); next }
    inblock                 { print > out }
  ' "$1"
}

if [ "${1:-}" = "--cli" ]; then
  post="$2"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  extract_blocks "$post" "$work"
  shopt -s nullglob
  for f in "$work"/block-*.mmd; do
    if npx -y @mermaid-js/mermaid-cli@11.4.2 -q -i "$f" -o "${f%.mmd}.svg" >/dev/null 2>"$f.err"; then
      echo "ok    $(basename "$f")"
    else
      echo "FAIL  $(basename "$f")"; cat "$f.err"; echo "--- block source:"; cat "$f"
      exit 1
    fi
  done
  exit 0
fi

post="$1"
out="$2"
mkdir -p "$out"
{
  echo '<!doctype html><meta charset="utf-8"><body style="max-width:760px;margin:2rem auto;font-family:Georgia,serif">'
  awk '/<pre class="mermaid">/{p=1} p{print} /<\/pre>/{p=0} /<figure>/{f=1} f{print} /<\/figure>/{f=0}' "$post"
  cat <<'JS'
<script type="module">
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
mermaid.initialize({ startOnLoad: false, theme: "neutral", securityLevel: "loose" });
window.results = [];
for (const el of document.querySelectorAll("pre.mermaid")) {
  try { await mermaid.run({ nodes: [el] }); window.results.push("ok"); }
  catch (e) { window.results.push("FAIL: " + e.message); }
}
window.done = true;
</script>
JS
} > "$out/test.html"
echo "Wrote $out/test.html ($(grep -c 'class="mermaid"' "$out/test.html") mermaid blocks)"

#!/usr/bin/bash

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

OFFICIAL_URL="https://gitlab.archlinux.org/archlinux/packaging/packages/linux-zen"

PATCHES=(
  "0001-x86-implement-tsc-directsync-for-systems-without-IA3.patch"
  "0002-x86-touch-clocksource-watchdog-after-syncing-TSCs.patch"
  "0003-x86-save-restore-TSC-counter-value-during-sleep-wake.patch"
  "0004-x86-only-restore-TSC-if-we-have-IA32_TSC_ADJUST-or-d.patch"
  "0005-x86-don-t-check-for-random-warps-if-using-direct-syn.patch"
  "0006-x86-disable-tsc-watchdog-if-using-direct-sync.patch"
)

TESTING=false
SKIP_PATCHES=false
while [ $# -gt 0 ]; do
  case "$1" in
    --testing) TESTING=true ;;
    --no-patches) SKIP_PATCHES=true ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

if [ "$SKIP_PATCHES" = false ]; then
  for p in "${PATCHES[@]}"; do
    if [[ ! -f "$p" ]]; then
      echo "Error: patch file '$p' not found in $DIR"
      exit 1
    fi
  done
fi

echo ":: Fetching tag list..."
TAGS_JSON=$(curl -sL "https://gitlab.archlinux.org/api/v4/projects/archlinux%2Fpackaging%2Fpackages%2Flinux-zen/repository/tags")
LATEST_TAG=$(echo "$TAGS_JSON" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data[0]['name'])")
EXTRA_TAG=$(echo "$TAGS_JSON" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data[1]['name'])")

if [ "$TESTING" = true ]; then
  TAG="$LATEST_TAG"
  REPO="extra-testing ($LATEST_TAG)"
else
  TAG="$EXTRA_TAG"
  REPO="extra ($EXTRA_TAG)"
fi

echo ":: Using tag: $TAG ($REPO)"

echo ":: Fetching official linux-zen PKGBUILD..."
curl -sL "$OFFICIAL_URL/-/raw/$TAG/PKGBUILD" -o PKGBUILD.official || {
  echo "Failed to fetch PKGBUILD from tag $TAG"
  exit 1
}

echo ":: Fetching official config.x86_64..."
curl -sL "$OFFICIAL_URL/-/raw/$TAG/config.x86_64" -o config.x86_64 || {
  echo "Failed to fetch config.x86_64"
  exit 1
}

echo ":: Fetching official source files..."
echo "  Downloading 0001-xfrm-esp-avoid-in-place-decrypt-on-shared-skb-frags.patch..."
if curl -sL --fail "$OFFICIAL_URL/-/raw/$TAG/0001-xfrm-esp-avoid-in-place-decrypt-on-shared-skb-frags.patch" \
  -o "0001-xfrm-esp-avoid-in-place-decrypt-on-shared-skb-frags.patch.tmp" 2>/dev/null; then
  mv "0001-xfrm-esp-avoid-in-place-decrypt-on-shared-skb-frags.patch.tmp" \
     "0001-xfrm-esp-avoid-in-place-decrypt-on-shared-skb-frags.patch"
  echo "  Downloaded 0001-xfrm-esp-avoid-in-place-decrypt-on-shared-skb-frags.patch"
else
  rm -f "0001-xfrm-esp-avoid-in-place-decrypt-on-shared-skb-frags.patch.tmp"
  echo "  Warning: not found in official repo (may have been merged upstream), keeping local copy"
fi

export TAG OFFICIAL_URL

python3 << 'PYEOF'
import os, re, subprocess, json

tag = os.environ.get('TAG', 'main')
official_url = os.environ.get('OFFICIAL_URL', 'https://gitlab.archlinux.org/archlinux/packaging/packages/linux-zen')

with open('PKGBUILD.official', 'r') as f:
    content = f.read()

# Find the source array and extract local file entries
src_match = re.search(r'^source=\((.*?)\)\s*^source_x86_64=', content, re.MULTILINE | re.DOTALL)
if src_match:
    src_content = src_match.group(1)
    for line in src_content.split('\n'):
        line = line.strip()
        if not line:
            continue
        # Strip quotes
        entry = line.strip('"').strip("'")
        # Skip URLs (have ://) and brace expansions
        if '://' in entry or '{' in entry:
            continue
        # Skip entries with shell variables (like $url)
        if '$' in entry:
            continue
        # This is a local file - download from the official repo
        filename = os.path.basename(entry)
        if not os.path.exists(filename):
            print(f"  Downloading {filename}...")
            result = subprocess.run(
                ['curl', '-sL', '-o', filename,
                 f'{official_url}/-/raw/{tag}/{entry}'],
                capture_output=True, text=True
            )
            if result.returncode != 0:
                print(f"  Warning: failed to download {filename}")
            else:
                print(f"  Downloaded {filename}")
PYEOF

echo ":: Modifying PKGBUILD..."

export SKIP_PATCHES TAG OFFICIAL_URL

python3 << 'PYEOF'
import os, re

skip_patches = os.environ.get('SKIP_PATCHES') == 'true'

with open('PKGBUILD.official', 'r') as f:
    content = f.read()

# 1. pkgbase
content = re.sub(r'^pkgbase=linux-zen$', 'pkgbase=linux-zen-directsync', content, flags=re.MULTILINE)

# 2. pkgdesc
content = re.sub(r"^pkgdesc='Linux ZEN'$", "pkgdesc='Linux ZEN with DirectSync'", content, flags=re.MULTILINE)

# 3. url
content = re.sub(
    r"^url='https://github.com/zen-kernel/zen-kernel'$",
    "url='https://github.com/damentz/zen-kernel'",
    content, flags=re.MULTILINE
)

if not skip_patches:
    patches = '''  "0001-x86-implement-tsc-directsync-for-systems-without-IA3.patch"
  "0002-x86-touch-clocksource-watchdog-after-syncing-TSCs.patch"
  "0003-x86-save-restore-TSC-counter-value-during-sleep-wake.patch"
  "0004-x86-only-restore-TSC-if-we-have-IA32_TSC_ADJUST-or-d.patch"
  "0005-x86-don-t-check-for-random-warps-if-using-direct-syn.patch"
  "0006-x86-disable-tsc-watchdog-if-using-direct-sync.patch"'''

    # 4. Add patches to source() array (before closing paren)
    content = re.sub(
        r'(source=\(.*?)\)(\s*source_x86_64=)',
        lambda m: m.group(1) + '\n' + patches + '\n)' + m.group(2),
        content,
        flags=re.DOTALL
    )

    # 5. DirectSync patches are applied in order via the loop (source array order is correct)

    # 6 & 7. Add 6 SKIP to sha256sums and b2sums
    def add_skips(m):
        inner = m.group(1)
        last_line = inner.rsplit('\n', 1)[-1] if '\n' in inner else ''
        indent = last_line[:len(last_line) - len(last_line.lstrip())]
        skips = '\n'.join([f"{indent}'SKIP'"] * 6)
        return inner + '\n' + skips + '\n' + indent + ')' + m.group(2)

    content = re.sub(
        r'(sha256sums=\([^)]+)\)(\s*\n)',
        add_skips,
        content,
        flags=re.DOTALL
    )

    content = re.sub(
        r'(b2sums=\([^)]+)\)(\s*\n)',
        add_skips,
        content,
        flags=re.DOTALL
    )

# 8. Add linux-zen to provides in _package()
content = re.sub(
    r'(WIREGUARD-MODULE\n\s+\))',
    r'WIREGUARD-MODULE\n    linux-zen\n  )',
    content
)

# 9. Add linux-zen to replaces in _package()
content = re.sub(
    r'(replaces=\(\n\s+\)\n)',
    r'replaces=(\n    linux-zen\n  )\n',
    content
)

# 10. Enable native CPU optimizations in build()
old_build = '''build() {
  cd $_srcname
  make all'''
new_build = '''build() {
  cd $_srcname

  echo "Enabling native CPU optimizations..."
  ./scripts/config --enable MNATIVE
  make olddefconfig

  make all'''

content = content.replace(old_build, new_build)

with open('PKGBUILD', 'w') as f:
    f.write(content)

print("Done")
PYEOF

echo ":: Cleaning up..."
rm -f PKGBUILD.official

echo ":: Done! Generated: PKGBUILD and config.x86_64"
echo "   Package: linux-zen-directsync (based on official linux-zen)"
echo "   Version: $TAG ($REPO)"
if [ "$SKIP_PATCHES" = false ]; then
  echo "   Patches added: ${#PATCHES[@]} directsync patches"
fi
echo ""
echo "   To build:               makepkg -si"
echo "   Testing branch:         $0 --testing"
echo "   Skip custom patches:    $0 --no-patches"

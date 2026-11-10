#!/usr/bin/env bash
# Test suite for the internal keyboard toggle.
# Run from anywhere:  bash tests/run-tests.sh
#
# Covers the external-keyboard count (the P0-1 regression): the count must be
# 0 with only the internal keyboard present, 1 per physical external keyboard,
# and the usb/usbv2 duplicate by-path link must count once. The same scenarios
# are run against the shell implementation (kbd-toggle) and the Python guard,
# because both must agree.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $*" >&2; }

assert_eq() {
    local got="$1" want="$2" what="$3"
    if [ "$got" = "$want" ]; then
        ok
    else
        bad "$what: expected '$want', got '$got'"
    fi
}

# --- Scenario builder -------------------------------------------------------
# Builds a mock /dev/input tree: regular files as event nodes, relative
# symlinks in by-path/, shaped exactly like the real thing. A spec ending in
# "(missing)" creates a dangling link, to model a half-removed device.
make_scenario() {  # $1: name; rest: "link_name -> event_node [(missing)]" specs
    local name="$1" dev="$TMP/$1"
    shift
    mkdir -p "$dev/input/by-path"
    for spec in "$@"; do
        local link target missing=""
        case "$spec" in
            *'(missing)') spec="${spec% (missing)}"; missing="1" ;;
        esac
        link="${spec%% ->*}"
        target="${spec##*-> }"
        if [ -z "$missing" ]; then
            touch "$dev/input/$target"
        fi
        ln -s "../$target" "$dev/input/by-path/$link"
    done
}

make_scenario internal-only \
    'platform-i8042-serio-0-event-kbd -> event4'
make_scenario one-external \
    'platform-i8042-serio-0-event-kbd -> event4' \
    'pci-0000:05:00.4-usb-0:2:1.2-event-kbd -> event8'
make_scenario two-external \
    'platform-i8042-serio-0-event-kbd -> event4' \
    'pci-0000:05:00.4-usb-0:2:1.2-event-kbd -> event8' \
    'pci-0000:05:00.4-usb-0:3:1.0-event-kbd -> event9'
make_scenario usb-duplicate \
    'platform-i8042-serio-0-event-kbd -> event4' \
    'pci-0000:05:00.4-usb-0:2:1.2-event-kbd -> event8' \
    'pci-0000:05:00.4-usbv2-0:2:1.2-event-kbd -> event8'
make_scenario no-internal-port \
    'pci-0000:05:00.4-usb-0:2:1.2-event-kbd -> event8'
make_scenario dead-link \
    'platform-i8042-serio-0-event-kbd -> event4' \
    'pci-0000:05:00.4-usb-0:2:1.2-event-kbd -> event99 (missing)'

# --- Shell: count_external_keyboards ---------------------------------------
# Extract just the function from kbd-toggle so the rest of the script
# (which performs real actions) never runs.
eval "$(sed -n '/^count_external_keyboards()/,/^}/p' "$ROOT/files/kbd-toggle")"
if ! declare -F count_external_keyboards >/dev/null; then
    echo "FATAL: could not extract count_external_keyboards from kbd-toggle" >&2
    exit 1
fi

echo "== kbd-toggle: count_external_keyboards"
assert_eq "$(BYPATH_DIR="$TMP/internal-only/input/by-path" count_external_keyboards)" \
    0 "internal keyboard only must count as 0 external"
assert_eq "$(BYPATH_DIR="$TMP/one-external/input/by-path" count_external_keyboards)" \
    1 "one external keyboard"
assert_eq "$(BYPATH_DIR="$TMP/two-external/input/by-path" count_external_keyboards)" \
    2 "two external keyboards"
assert_eq "$(BYPATH_DIR="$TMP/usb-duplicate/input/by-path" count_external_keyboards)" \
    1 "usb/usbv2 duplicate link counts once"
assert_eq "$(BYPATH_DIR="$TMP/no-internal-port/input/by-path" count_external_keyboards)" \
    1 "external only"
assert_eq "$(BYPATH_DIR="$TMP/dead-link/input/by-path" count_external_keyboards)" \
    0 "dead by-path link is not counted"

# Real system sanity, when run on the target laptop: the live count must be a
# number and must never include the internal keyboard. It is informational,
# not an assertion on a fixed value.
if [ -d /dev/input/by-path ]; then
    real="$(BYPATH_DIR=/dev/input/by-path count_external_keyboards)"
    echo "   live /dev/input/by-path external count: $real"
    assert_eq "$([ "$real" -ge 0 ] 2>/dev/null && echo numeric || echo broken)" \
        numeric "live count is a number"
fi

# --- Python guard: mirror of the count --------------------------------------
echo "== kbd-guard.py: count_external_keyboards"
KBD_TMP="$TMP" PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/test-guard-count.py" \
    || bad "guard-side count tests failed"

# --- Syntax checks -----------------------------------------------------------
echo "== syntax checks"
for script in kbd-toggle kbd-internal; do
    if bash -n "$ROOT/files/$script" 2>/dev/null; then
        ok
    else
        bad "$script does not parse"
    fi
done
for script in install.sh uninstall.sh; do
    if bash -n "$ROOT/$script" 2>/dev/null; then
        ok
    else
        bad "$script does not parse"
    fi
done
if PYTHONDONTWRITEBYTECODE=1 python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" \
        "$ROOT/files/kbd-guard.py" 2>/dev/null; then
    ok
else
    bad "kbd-guard.py does not parse"
fi
# The service unit and sudoers are rendered at install time; validate the
# templates substitute to files the real validators accept.
rendered_sudoers="$TMP/sudoers"
sed "s|__USER__|vairam|" "$ROOT/files/kbd-toggle.sudoers" >"$rendered_sudoers"
if visudo -c -f "$rendered_sudoers" >/dev/null 2>&1; then
    ok
else
    bad "rendered sudoers rule does not validate"
fi
rendered_unit="$TMP/kbd-guard.service"
sed -e "s|__HOME__|/home/vairam|g" -e "s|__DOC__|/home/vairam/kbd-toggle|g" \
    "$ROOT/files/kbd-guard.service" >"$rendered_unit"
if systemd-analyze verify "$rendered_unit" >/dev/null 2>&1; then
    ok
else
    # Non-fatal: systemd-analyze flags ExecStopPost target paths it cannot
    # stat at verify time; report but don't fail.
    echo "   note: systemd-analyze verify reported issues on the rendered unit:"
    systemd-analyze verify "$rendered_unit" 2>&1 | sed 's/^/     /' | head -5
fi

# --- Extension metadata, schema and JS --------------------------------------
echo "== extension metadata"
META="$ROOT/files/extension/metadata.json"
if python3 - "$META" <<'PY' >/dev/null 2>&1
import json, sys
meta = json.load(open(sys.argv[1]))
required = ("uuid", "name", "description", "shell-version", "url",
            "version", "version-name", "settings-schema", "session-modes")
missing = [k for k in required if k not in meta]
if missing:
    raise SystemExit("missing keys: " + ", ".join(missing))
if meta["settings-schema"] != "org.gnome.shell.extensions.kbd-toggle":
    raise SystemExit("settings-schema does not match the shipped schema id")
if "unlock-dialog" not in meta["session-modes"]:
    raise SystemExit("session-modes must include unlock-dialog")
PY
then
    ok
else
    bad "metadata.json is missing a required key or has a wrong value"
fi

echo "== extension schema"
SCHEMA_DIR="$TMP/schemas"
mkdir -p "$SCHEMA_DIR"
cp "$ROOT/files/extension/schemas/"*.gschema.xml "$SCHEMA_DIR/"
if glib-compile-schemas --strict "$SCHEMA_DIR" 2>"$TMP/schema.err"; then
    ok
else
    bad "the GSettings schema does not compile: $(head -1 "$TMP/schema.err")"
fi
# The key has to exist in the schema and be read by the extension, or the
# preferences window would edit a value nothing consumes.
if grep -q 'name="poll-interval-seconds"' "$SCHEMA_DIR"/*.gschema.xml &&
    grep -q "get_int('poll-interval-seconds')" "$ROOT/files/extension/extension.js"; then
    ok
else
    bad "poll-interval-seconds is not wired between the schema and extension.js"
fi

echo "== extension JS parses"
if command -v gjs >/dev/null 2>&1; then
    for js in extension.js prefs.js; do
        # Outside gnome-shell the shell's resource:/// imports cannot resolve,
        # which is expected. A syntax error is reported differently, as
        # "Failed to parse module". LD_LIBRARY_PATH is cleared because some
        # editors export their own libstdc++, which breaks gjs.
        out="$(env -u LD_LIBRARY_PATH gjs -m "$ROOT/files/extension/$js" 2>&1 | tr '\n' ' ')"
        case "$out" in
            *"Failed to parse module"*) bad "$js does not parse: $out" ;;
            *) ok ;;
        esac
    done
else
    echo "   note: gjs not found, skipping the JS parse check"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]

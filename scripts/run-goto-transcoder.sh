#!/bin/bash
# Verify Kani-generated CBMC goto-binaries with ESBMC.
#
# ESBMC reads CBMC goto-binaries natively (`esbmc --binary prog.out`), so this no
# longer shells out to the out-of-process `goto-transcoder` converter, and no
# longer needs a separate CPROVER library goto-binary.  The script name is kept
# because the workflow job it backs is a required status check.
#
# Usage:
#   run-goto-transcoder.sh <kani-target-dir> [harness-regex]
#
# <kani-target-dir>  the --target-dir given to run-kani.sh (e.g. kani/contracts)
# [harness-regex]    optional ERE selecting harnesses; when omitted, the families
#                    in tool_config/esbmc-supported-harnesses.txt are used.
#
# Environment:
#   ESBMC_BIN      path to an esbmc binary; when unset, one is built from source
#   ESBMC_REPO     ESBMC git remote            (default: esbmc/esbmc on GitHub)
#   ESBMC_REF      ESBMC commit/branch to build (default: master)
#   ESBMC_TIMEOUT  per-harness solver cap in seconds (default: 120)
#   JOBS           parallel harnesses          (default: nproc)

set -euo pipefail

##############
# PARAMETERS #
##############
TARGET_DIR=${1:-}
HARNESS_RE=${2:-}

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PATTERN_FILE="$REPO_ROOT/tool_config/esbmc-supported-harnesses.txt"

ESBMC_REPO=${ESBMC_REPO:-https://github.com/esbmc/esbmc.git}
ESBMC_REF=${ESBMC_REF:-master}
ESBMC_TIMEOUT=${ESBMC_TIMEOUT:-120}
JOBS=${JOBS:-$(nproc)}

if [[ -z "$TARGET_DIR" ]]; then
    echo "Usage: $0 <kani-target-dir> [harness-regex]" >&2
    exit 1
fi

#########
# ESBMC #
#########
build_esbmc() {
    local src="$REPO_ROOT/esbmc_build"

    if [[ ! -d "$src/.git" ]]; then
        echo "Fetching ESBMC ($ESBMC_REF) ..."
        # Fetch by ref rather than clone --branch, so ESBMC_REF may be either a
        # branch name or a commit SHA.
        mkdir -p "$src"
        git -C "$src" init -q
        git -C "$src" remote add origin "$ESBMC_REPO"
        git -C "$src" fetch -q --depth 1 origin "$ESBMC_REF"
        git -C "$src" checkout -q FETCH_HEAD
    fi

    echo "Building ESBMC at $(git -C "$src" rev-parse --short HEAD) ..."
    # Bitwuzla is bundled via DOWNLOAD_DEPENDENCIES; Boolector is left off because
    # it needs a system SAT solver that the runner image does not ship.
    cmake -S "$src" -B "$src/build" -GNinja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DBUILD_STATIC=ON \
        -DDOWNLOAD_DEPENDENCIES=On \
        -DENABLE_Z3=ON -DENABLE_BITWUZLA=On -DENABLE_BOOLECTOR=Off \
        -DENABLE_REGRESSION=Off
    ninja -C "$src/build" -j"$JOBS" esbmc

    echo "$src/build/src/esbmc/esbmc"
}

if [[ -n "${ESBMC_BIN:-}" ]]; then
    ESBMC="$ESBMC_BIN"
else
    ESBMC=$(build_esbmc | tail -1)
fi

"$ESBMC" --version

##########
# CORPUS #
##########
# Kani writes one goto-binary per harness next to the crate's other artefacts.
# There is more than one */debug/deps under the target dir (build scripts and the
# dummy crate get their own); the one we want is the one holding goto-binaries.
DEPS_DIR=""
while IFS= read -r d; do
    if compgen -G "$d/*.out" > /dev/null; then DEPS_DIR="$d"; break; fi
done < <(find "$TARGET_DIR" -type d -path '*/debug/deps')

if [[ -z "$DEPS_DIR" ]]; then
    echo "No */debug/deps directory holding *.out under '$TARGET_DIR'" >&2
    echo "— did run-kani.sh --only-codegen --keep-temps run?" >&2
    exit 1
fi
echo "Corpus: $DEPS_DIR"

if [[ -z "$HARNESS_RE" ]]; then
    if [[ ! -f "$PATTERN_FILE" ]]; then
        echo "Missing $PATTERN_FILE and no regex given" >&2
        exit 1
    fi
    # Join the non-comment lines into one alternation.
    HARNESS_RE=$(grep -vE '^[[:space:]]*(#|$)' "$PATTERN_FILE" | paste -sd '|' -)
fi
echo "Selecting harnesses matching: $HARNESS_RE"

# .symtab.out is Kani's intermediate symbol table, not a linked goto-binary.
#
# The expressions are matched against the mangled *symbol*, not the path, so that
# they can be anchored with '$' without tripping over the .out extension.
mapfile -t HARNESSES < <(
    find "$DEPS_DIR" -name '*.out' ! -name '*.symtab.out' \
        | while IFS= read -r f; do
              b=${f##*/}; sym="_${b#*__}"; sym="${sym%.out}"
              if [[ "$sym" =~ $HARNESS_RE ]]; then echo "$f"; fi
          done | sort
)

if [[ ${#HARNESSES[@]} -eq 0 ]]; then
    echo "No harness matched — refusing to report success on an empty run." >&2
    exit 1
fi
echo "Found ${#HARNESSES[@]} harnesses"

###########
# VERIFY  #
###########
RESULTS=$(mktemp -d)
trap 'rm -rf "$RESULTS"' EXIT

verify_one() {
    local file="$1" base sym log
    base=$(basename "$file")
    # core-<hash>__<mangled>.out  ->  _<mangled>
    sym="_${base#*__}"; sym="${sym%.out}"
    log="$RESULTS/$base.log"

    if timeout -k 5 $((ESBMC_TIMEOUT + 30)) \
            "$ESBMC" --binary "$file" --function "$sym" \
            --timeout "$ESBMC_TIMEOUT" > "$log" 2>&1 \
       && grep -q "VERIFICATION SUCCESSFUL" "$log"; then
        echo "PASS $sym" >> "$RESULTS/summary"
    else
        echo "FAIL $sym" >> "$RESULTS/summary"
        {
            echo "=== $sym"
            grep -vE "^WARNING: CBMC adapter: dropping" "$log" | tail -25
        } >> "$RESULTS/failures"
    fi
}
export -f verify_one
export ESBMC ESBMC_TIMEOUT RESULTS

printf '%s\n' "${HARNESSES[@]}" \
    | xargs -P "$JOBS" -I{} bash -c 'verify_one "$@"' _ {}

PASSED=$(grep -c '^PASS' "$RESULTS/summary" || true)
FAILED=$(grep -c '^FAIL' "$RESULTS/summary" || true)

echo
echo "==================================================="
echo " ESBMC: $PASSED passed, $FAILED failed, of ${#HARNESSES[@]}"
echo "==================================================="

if [[ "$FAILED" -gt 0 ]]; then
    echo
    echo "Failing harnesses:"
    grep '^FAIL' "$RESULTS/summary" | sort
    echo
    cat "$RESULTS/failures"
    exit 1
fi

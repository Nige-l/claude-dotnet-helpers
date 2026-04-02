#!/usr/bin/env bash
# dotnet-helpers.sh — .NET build/test/cleanup helper for AI agent MCP plugins
# MIT License — Copyright 2026 Nigel Johnson
#
# Self-contained: no external dependencies beyond bash, dotnet, jq, ps, awk, grep.
# Works on any .NET 8+ project. Nothing project-specific in this file.
#
# Commands:
#   build [--project <path>] [--configuration <config>] [--json]
#   test  --project <path> [--filter <expr>] [--configuration <config>] [--json]
#   cleanup [--json]
#   analyze-errors <file> [--json]
#
set -euo pipefail

command -v dotnet >/dev/null 2>&1 || { echo '{"status":"error","message":"dotnet not found. Install .NET 8+ SDK."}'; exit 1; }
command -v jq >/dev/null 2>&1 || { echo '{"status":"error","message":"jq not found. Install jq."}'; exit 1; }

# ---------------------------------------------------------------------------
# Color detection & print helpers
# ---------------------------------------------------------------------------

if [[ -n "${NO_COLOR:-}" || ! -t 1 || "${JSON_OUTPUT:-false}" == "true" ]]; then
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" RESET=""
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
fi

ok()   { [[ "${JSON_OUTPUT:-false}" == "true" ]] && return 0; printf "  ${GREEN}ok${RESET} %s\n" "$*"; }
err()  { printf "  ${RED}error${RESET} %s\n" "$*" >&2; }
warn() { [[ "${JSON_OUTPUT:-false}" == "true" ]] && return 0; printf "  ${YELLOW}warn${RESET} %s\n" "$*"; }
info() { [[ "${JSON_OUTPUT:-false}" == "true" ]] && return 0; printf "  ${CYAN}info${RESET} %s\n" "$*"; }
bold() { [[ "${JSON_OUTPUT:-false}" == "true" ]] && return 0; printf "${BOLD}%s${RESET}\n" "$*"; }

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

# json_str: safely escape a string for embedding in a JSON value.
# Handles backslash, double-quote, newline, carriage-return, tab, backspace, form-feed,
# and strips other control chars. Does NOT emit surrounding quotes.
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"       # \ -> \\
    s="${s//\"/\\\"}"       # " -> \"
    s="${s//$'\n'/\\n}"     # LF -> \n
    s="${s//$'\r'/\\r}"     # CR -> \r
    s="${s//$'\t'/\\t}"     # tab -> \t
    s="${s//$'\b'/\\b}"     # backspace -> \b
    s="${s//$'\f'/\\f}"     # form feed -> \f
    # Strip remaining control chars (0x00–0x08, 0x0b, 0x0e–0x1f)
    s=$(printf '%s' "$s" | tr -d '\000-\010\013\016-\037')
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Process helpers (used by cleanup)
# ---------------------------------------------------------------------------

# pids_of <pattern> — print one PID per line matching pattern (excludes self + grep)
pids_of() {
    local pattern="$1"
    local first="${pattern:0:1}"
    local rest="${pattern:1}"
    ps aux 2>/dev/null \
        | grep -E "[${first}]${rest}" \
        | grep -v "grep" \
        | awk '{print $2}' \
        || true
}

# mem_mb_of <pid> — resident memory in MB
mem_mb_of() {
    local pid="$1"
    local rss
    rss=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ') || rss=0
    echo $(( ${rss:-0} / 1024 ))
}

# cmd_of <pid> — full command line
cmd_of() {
    local pid="$1"
    ps -p "$pid" -o args= 2>/dev/null || echo "(unknown)"
}

# graceful_kill <pid> — SIGTERM then SIGKILL after 5s
graceful_kill() {
    local pid="$1"
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0  # already gone
    fi
    kill -TERM "$pid" 2>/dev/null || return 0
    local waited=0
    while [[ $waited -lt 5 ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Build error parsing
# ---------------------------------------------------------------------------

# parse_errors <input_file>
# Outputs tab-separated stream: category TAB code TAB file TAB line TAB message
parse_errors() {
    local input_file="$1"

    while IFS=$'\t' read -r code file_base file_line msg; do
        local category
        case "$code" in
            CS0246|CS0234)        category="MISSING_TYPES" ;;
            CS1501|CS1503|CS7036) category="API_MISMATCH" ;;
            CS0117|CS1061)        category="MEMBER_NOT_FOUND" ;;
            CS8177|CS8175)        category="REF_ASYNC" ;;
            CS0029|CS0266)        category="TYPE_CONFLICTS" ;;
            CS0111|CS0101)        category="DUPLICATE" ;;
            *)                    category="OTHER" ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\n' "$category" "$code" "$file_base" "$file_line" "$msg"
    done < <(
        { grep -E ': error CS[0-9]+:' "$input_file" || true; } \
        | awk -F': error ' '{
            error_part = $2
            code = ""
            if (match(error_part, /CS[0-9]+/)) {
                code = substr(error_part, RSTART, RLENGTH)
            }
            msg = error_part
            sub(/CS[0-9]+: /, "", msg)

            file_part = $1
            file_line = "0"
            file_base = file_part
            if (match(file_part, /\([0-9]+/)) {
                raw_path = substr(file_part, 1, RSTART - 1)
                file_line = substr(file_part, RSTART + 1, RLENGTH - 1)
                n = split(raw_path, parts, "/")
                file_base = parts[n]
            } else {
                n = split(file_part, parts, "/")
                file_base = parts[n]
            }
            print code "\t" file_base "\t" file_line "\t" msg
        }'
    )
}

# count_warnings <input_file>
count_warnings() {
    local n
    n=$(grep -c ': warning CS' "$1" 2>/dev/null) || n=0
    printf '%s' "$n"
}

# build_succeeded <input_file>
build_succeeded() {
    grep -qE 'Build succeeded' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# build_output_to_json <project_label> <build_file> <build_exit_code>
# Emits the full JSON object for the build command. Uses jq for all construction.
# ---------------------------------------------------------------------------
build_output_to_json() {
    local proj_label="$1"
    local build_file="$2"
    local build_exit_code="${3:-0}"

    local total_errors
    total_errors=$(grep -c ': error CS' "$build_file" 2>/dev/null) || total_errors=0
    local total_warnings
    total_warnings=$(count_warnings "$build_file")
    local succeeded="false"
    build_succeeded "$build_file" && succeeded="true" || true

    local non_compiler_failure="false"
    if [[ "$build_exit_code" -ne 0 && "$total_errors" -eq 0 ]]; then
        non_compiler_failure="true"
        succeeded="false"
    fi

    if [[ "$total_errors" -eq 0 ]]; then
        jq -n \
            --arg     project              "$proj_label" \
            --argjson succeeded            "$succeeded" \
            --argjson errors               0 \
            --argjson warnings             "$total_warnings" \
            --argjson build_exit_code      "$build_exit_code" \
            --argjson non_compiler_failure "$non_compiler_failure" \
            '{project:$project,succeeded:$succeeded,errors:$errors,
              warnings:$warnings,build_exit_code:$build_exit_code,
              non_compiler_failure:$non_compiler_failure,
              categories:{},files:{},fix_order:[]}'
        return 0
    fi

    local parsed_file
    parsed_file=$(mktemp /tmp/dotnet_helpers_parsed.XXXXXX)
    parse_errors "$build_file" > "$parsed_file"

    # Build a JSONL file: one JSON object per error, all fields safely escaped by jq
    local errors_jsonl
    errors_jsonl=$(mktemp /tmp/dotnet_helpers_errors.XXXXXX)

    while IFS=$'\t' read -r cat code file lnum msg; do
        jq -n \
            --arg category "$cat" \
            --arg code     "$code" \
            --arg file     "$file" \
            --arg line     "$lnum" \
            --arg message  "$msg" \
            '{category:$category,code:$code,file:$file,line:$line,message:$message}' \
            >> "$errors_jsonl"
    done < "$parsed_file"

    jq -n \
        --arg     project              "$proj_label" \
        --argjson succeeded            "$succeeded" \
        --argjson total_errors         "$total_errors" \
        --argjson total_warnings       "$total_warnings" \
        --argjson build_exit_code      "$build_exit_code" \
        --argjson non_compiler_failure "$non_compiler_failure" \
        --slurpfile all_errors         "$errors_jsonl" \
        '
        ($all_errors | group_by(.category)) as $grouped |
        ($grouped | map({
            key: .[0].category,
            value: {
                count: length,
                errors: map({code:.code,file:.file,line:.line,message:.message})
            }
        }) | from_entries) as $categories |
        ($all_errors | group_by(.file)
         | map({key:.[0].file,value:length})
         | from_entries) as $files |
        (["MISSING_TYPES","API_MISMATCH","MEMBER_NOT_FOUND","REF_ASYNC","TYPE_CONFLICTS","DUPLICATE","OTHER"]
         | map(. as $k | if $categories[$k] then {category:$k,count:$categories[$k].count} else empty end)
        ) as $fix_order |
        {
            project:              $project,
            succeeded:            $succeeded,
            errors:               $total_errors,
            warnings:             $total_warnings,
            build_exit_code:      $build_exit_code,
            non_compiler_failure: $non_compiler_failure,
            categories:           $categories,
            files:                $files,
            fix_order:            $fix_order
        }
        '

    rm -f "$parsed_file" "$errors_jsonl"
}

# build_output_human <project_label> <build_file> <build_exit_code>
build_output_human() {
    local proj_label="$1"
    local build_file="$2"
    local build_exit_code="${3:-0}"

    local total_errors
    total_errors=$(grep -c ': error CS' "$build_file" 2>/dev/null) || total_errors=0
    local total_warnings
    total_warnings=$(count_warnings "$build_file")

    bold ""
    bold "=== Build Analysis: $proj_label ==="

    if build_succeeded "$build_file" && [[ "$total_errors" -eq 0 ]]; then
        ok "Result: SUCCEEDED ($total_warnings warnings)"
        return 0
    fi

    err "Result: FAILED ($total_errors errors, $total_warnings warnings)"
    echo ""

    if [[ "$total_errors" -eq 0 ]]; then
        if [[ "$build_exit_code" -ne 0 ]]; then
            err "BUILD FAILED (non-compiler error — dotnet exit code $build_exit_code)"
            warn "Not a CS compile error. Possible causes:"
            warn "  • Missing .NET SDK or wrong SDK version"
            warn "  • MSBuild project file error (missing reference, bad XML)"
            warn "  • Out-of-memory / process crash"
            warn "  • Missing NuGet packages (try: dotnet restore)"
        else
            warn "No CS errors found — build may have failed for other reasons."
        fi
        return 1
    fi

    local parsed_file
    parsed_file=$(mktemp /tmp/dotnet_helpers_parsed.XXXXXX)
    parse_errors "$build_file" > "$parsed_file"

    declare -a CAT_KEYS=( MISSING_TYPES API_MISMATCH MEMBER_NOT_FOUND REF_ASYNC TYPE_CONFLICTS DUPLICATE OTHER )
    declare -A CAT_LABEL=(
        [MISSING_TYPES]="MISSING TYPES"
        [API_MISMATCH]="API MISMATCH"
        [MEMBER_NOT_FOUND]="MEMBER NOT FOUND"
        [REF_ASYNC]="REF/ASYNC VIOLATIONS"
        [TYPE_CONFLICTS]="TYPE CONFLICTS"
        [DUPLICATE]="DUPLICATE DEFINITIONS"
        [OTHER]="OTHER"
    )
    declare -A CAT_HINT=(
        [MISSING_TYPES]="fix these first — may resolve cascading errors; add missing using statements or project references"
        [API_MISMATCH]="check correct method signatures"
        [MEMBER_NOT_FOUND]="grep codebase for renamed or removed members"
        [REF_ASYNC]="never use ref locals in async methods or lambdas (CS8177/CS8175)"
        [TYPE_CONFLICTS]="check component type conversions; verify correct struct vs class"
        [DUPLICATE]="usually merge conflicts — deduplicate definitions"
        [OTHER]="review each error individually"
    )

    declare -A CAT_COUNT
    declare -A FILE_COUNT

    for key in "${CAT_KEYS[@]}"; do
        CAT_COUNT[$key]=0
    done

    while IFS=$'\t' read -r cat code file lnum msg; do
        CAT_COUNT[$cat]=$(( ${CAT_COUNT[$cat]:-0} + 1 ))
        FILE_COUNT[$file]=$(( ${FILE_COUNT[$file]:-0} + 1 ))
    done < "$parsed_file"

    for key in "${CAT_KEYS[@]}"; do
        local cnt=${CAT_COUNT[$key]:-0}
        [[ "$cnt" -eq 0 ]] && continue
        printf "\n${BOLD}${YELLOW}%s${RESET} ${BOLD}(%d error%s)${RESET} — %s:\n" \
            "${CAT_LABEL[$key]}" "$cnt" "$( [[ $cnt -eq 1 ]] && echo "" || echo "s" )" \
            "${CAT_HINT[$key]}"
        local shown=0
        while IFS=$'\t' read -r cat code file lnum msg; do
            [[ "$cat" != "$key" ]] && continue
            if [[ $shown -lt 15 ]]; then
                printf "  ${RED}%s${RESET} in ${CYAN}%s${RESET}(%s): %s\n" "$code" "$file" "$lnum" "$msg"
            elif [[ $shown -eq 15 ]]; then
                printf "  ${YELLOW}... and %d more %s errors${RESET}\n" "$(( cnt - 15 ))" "$key"
            fi
            shown=$(( shown + 1 ))
        done < "$parsed_file"
    done

    echo ""
    bold "FIX ORDER:"
    local order=1
    for key in "${CAT_KEYS[@]}"; do
        local cnt=${CAT_COUNT[$key]:-0}
        [[ "$cnt" -eq 0 ]] && continue
        printf "  %d. %s (%d) — %s\n" "$order" "${CAT_LABEL[$key]}" "$cnt" "${CAT_HINT[$key]}"
        order=$(( order + 1 ))
    done

    echo ""
    bold "FILES TO FIX (by error count):"
    for f in "${!FILE_COUNT[@]}"; do
        printf '%d\t%s\n' "${FILE_COUNT[$f]}" "$f"
    done | sort -rn | head -10 | while IFS=$'\t' read -r cnt file; do
        printf "  %-50s — %d error%s\n" "$file" "$cnt" "$( [[ $cnt -eq 1 ]] && echo "" || echo "s" )"
    done

    rm -f "$parsed_file"
    return 1
}

# ---------------------------------------------------------------------------
# cmd_build
# ---------------------------------------------------------------------------
# Usage: build [--project <path>] [--configuration <config>] [--json]
cmd_build() {
    local project=""
    local configuration="Debug"
    local json_mode="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)       project="$2";        shift 2 ;;
            --configuration) configuration="$2";  shift 2 ;;
            --json)          json_mode="true";     shift ;;
            *) err "build: unknown option: $1"; usage_build; exit 1 ;;
        esac
    done

    if [[ -z "$project" ]]; then
        err "build: --project <path> is required"
        usage_build
        exit 1
    fi

    if [[ ! -f "$project" && ! -d "$project" ]]; then
        err "build: project not found: $project"
        exit 1
    fi

    local tmp_out
    tmp_out=$(mktemp /tmp/dotnet_helpers_build.XXXXXX)
    # Ensure cleanup even on error
    trap 'rm -f "$tmp_out"' EXIT INT TERM

    info "Building $project (configuration=$configuration)..."

    local build_exit_code=0
    dotnet build "$project" \
        --nologo \
        -c "$configuration" \
        --no-incremental \
        2>&1 | tee "$tmp_out" > /dev/null \
        || build_exit_code="${PIPESTATUS[0]}"

    if [[ "$json_mode" == "true" ]]; then
        JSON_OUTPUT=true build_output_to_json "$project" "$tmp_out" "$build_exit_code"
    else
        build_output_human "$project" "$tmp_out" "$build_exit_code" || true
    fi

    rm -f "$tmp_out"
    trap - EXIT INT TERM

    return "$build_exit_code"
}

usage_build() {
    cat <<'EOF'
build [--project <path>] [--configuration <config>] [--json]

  Run dotnet build on a project, parse MSBuild output, and categorize errors.

  Options:
    --project <path>         Path to .csproj or directory (required)
    --configuration <name>   Build configuration (default: Release)
    --json                   Output structured JSON

  JSON output shape:
    {project, succeeded, errors, warnings, build_exit_code, non_compiler_failure,
     categories: {CAT: {count, errors: [{code, file, line, message}]}},
     files: {file: count},
     fix_order: [{category, count}]}

  Error categories (in fix priority order):
    MISSING_TYPES     CS0246, CS0234  — fix first; may resolve cascades
    API_MISMATCH      CS1501, CS1503, CS7036
    MEMBER_NOT_FOUND  CS0117, CS1061
    REF_ASYNC         CS8177, CS8175  — ref locals in async/lambda
    TYPE_CONFLICTS    CS0029, CS0266
    DUPLICATE         CS0111, CS0101
    OTHER             everything else
EOF
}

# ---------------------------------------------------------------------------
# cmd_test
# ---------------------------------------------------------------------------
# Usage: test --project <path> [--filter <expr>] [--configuration <config>] [--json]
cmd_test() {
    local project=""
    local filter=""
    local configuration="Debug"
    local json_mode="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)       project="$2";        shift 2 ;;
            --filter)        filter="$2";          shift 2 ;;
            --configuration) configuration="$2";  shift 2 ;;
            --json)          json_mode="true";     shift ;;
            *) err "test: unknown option: $1"; usage_test; exit 1 ;;
        esac
    done

    if [[ -z "$project" ]]; then
        err "test: --project <path> is required"
        usage_test
        exit 1
    fi

    if [[ ! -f "$project" && ! -d "$project" ]]; then
        err "test: project not found: $project"
        exit 1
    fi

    local extra_args=()
    [[ -n "$filter" ]] && extra_args+=("--filter" "$filter")

    local tmp_out
    tmp_out=$(mktemp /tmp/dotnet_helpers_test.XXXXXX)
    trap 'rm -f "$tmp_out"' EXIT INT TERM

    local start_ts end_ts duration_ms duration_s
    start_ts=$(date +%s%N)

    local test_exit_code=0
    dotnet test "$project" \
        --verbosity normal \
        --nologo \
        --no-build \
        -c "$configuration" \
        "${extra_args[@]}" \
        > "$tmp_out" 2>&1 \
        || test_exit_code=$?

    end_ts=$(date +%s%N)
    duration_ms=$(( (end_ts - start_ts) / 1000000 ))
    duration_s=$(awk "BEGIN{printf \"%.1f\", $duration_ms/1000}")

    # ---------------------------------------------------------------------------
    # Parse test counts — handles multiple dotnet test output formats:
    # Format 1 (multi-line xUnit): separate "Passed:", "Failed:", "Skipped:" lines
    # Format 2/3 (single-line VSTest): "Passed! - Failed: 0, Passed: N, ..."
    # Format 4 (mocha-style): "N passing / M failing"
    # ---------------------------------------------------------------------------
    local _pass=0 _fail=0 _skip=0

    local p f s
    p=$(grep -oP '^\s*Passed:\s*\K[0-9]+' "$tmp_out" | head -1 || true)
    f=$(grep -oP '^\s*Failed:\s*\K[0-9]+' "$tmp_out" | head -1 || true)
    s=$(grep -oP '^\s*Skipped:\s*\K[0-9]+' "$tmp_out" | head -1 || true)

    if [[ -n "$p" || -n "$f" ]]; then
        _pass=${p:-0}; _fail=${f:-0}; _skip=${s:-0}
    else
        local summary_line
        summary_line=$(grep -E -i "(Passed|Failed|Skipped).*Total|Total.*Passed|Test Run|Passed!|Failed!" "$tmp_out" | tail -1 || true)
        p=$(printf '%s' "$summary_line" | grep -oP 'Passed:\s*\K[0-9]+' || true)
        f=$(printf '%s' "$summary_line" | grep -oP 'Failed:\s*\K[0-9]+' || true)
        s=$(printf '%s' "$summary_line" | grep -oP 'Skipped:\s*\K[0-9]+' || true)
        _pass=${p:-0}; _fail=${f:-0}; _skip=${s:-0}
    fi

    # Format 4 fallback
    if [[ "$_pass" == "0" && "$_fail" == "0" ]]; then
        p=$(grep -oP '^\s*\K[0-9]+(?= passing)' "$tmp_out" | head -1 || true)
        f=$(grep -oP '^\s*\K[0-9]+(?= failing)' "$tmp_out" | head -1 || true)
        _pass=${p:-0}; _fail=${f:-0}
    fi

    # Non-zero exit with no tests detected → count as 1 failure
    if [[ $test_exit_code -ne 0 && "$_pass" == "0" && "$_fail" == "0" ]]; then
        _fail=1
    fi

    local total=$(( _pass + _fail + _skip ))
    local succeeded="false"
    [[ "$_fail" -eq 0 && $test_exit_code -eq 0 ]] && succeeded="true"

    # ---------------------------------------------------------------------------
    # Parse individual failure blocks
    # xUnit: "  Failed SomeTest.Name [42ms]" followed by indented message lines
    # ---------------------------------------------------------------------------
    local failures_jsonl
    failures_jsonl=$(mktemp /tmp/dotnet_helpers_failures.XXXXXX)

    if [[ "$_fail" -gt 0 ]]; then
        local in_failure=false
        local current_name="" current_msg="" current_file=""

        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*(X|✗|Failed)[[:space:]]+(.+) ]]; then
                # Flush previous failure
                if [[ -n "$current_name" ]]; then
                    jq -n \
                        --arg name    "$current_name" \
                        --arg message "$current_msg" \
                        --arg file    "$current_file" \
                        '{name:$name,message:$message,file:$file}' \
                        >> "$failures_jsonl"
                fi
                local marker_rest="${BASH_REMATCH[2]}"
                if [[ "$marker_rest" =~ ^([^[:space:]]+) ]]; then
                    current_name="${BASH_REMATCH[1]}"
                else
                    current_name="$marker_rest"
                fi
                current_msg=""
                current_file=""
                in_failure=true
            elif $in_failure; then
                if [[ "$line" =~ [^[:space:]]+\.(cs|fs):[0-9]+ ]]; then
                    current_file="${BASH_REMATCH[0]}"
                    in_failure=false
                elif [[ -z "$current_msg" ]] && [[ "$line" =~ [^[:space:]] ]]; then
                    if [[ "$line" =~ ^[[:space:]]*(.+)$ ]]; then
                        current_msg="${BASH_REMATCH[1]}"
                    else
                        current_msg="$line"
                    fi
                fi
            fi
        done < "$tmp_out"

        # Flush last failure
        if [[ -n "$current_name" ]]; then
            jq -n \
                --arg name    "$current_name" \
                --arg message "$current_msg" \
                --arg file    "$current_file" \
                '{name:$name,message:$message,file:$file}' \
                >> "$failures_jsonl"
        fi
    fi

    rm -f "$tmp_out"
    trap - EXIT INT TERM

    if [[ "$json_mode" == "true" ]]; then
        # Build failures array from jsonl (may be empty file)
        local failures_json="[]"
        if [[ -s "$failures_jsonl" ]]; then
            failures_json=$(jq -s '.' "$failures_jsonl")
        fi
        rm -f "$failures_jsonl"

        jq -n \
            --arg     project    "$project" \
            --argjson duration_s "$duration_s" \
            --argjson passed     "$_pass" \
            --argjson failed     "$_fail" \
            --argjson skipped    "$_skip" \
            --argjson total      "$total" \
            --argjson succeeded  "$succeeded" \
            --argjson failures   "$failures_json" \
            '{project:$project,duration_s:$duration_s,
              passed:$passed,failed:$failed,skipped:$skipped,total:$total,
              succeeded:$succeeded,failures:$failures}'
    else
        bold ""
        bold "=== Test Results: $project ==="
        printf "\nDuration: ${CYAN}${duration_s}s${RESET}\n\n"

        if [[ "$_fail" -eq 0 ]]; then
            printf "${GREEN}${BOLD}PASSED: %d/%d${RESET}\n" "$_pass" "$total"
        else
            printf "${GREEN}PASSED: %d/%d${RESET}\n" "$_pass" "$total"
            printf "${RED}${BOLD}FAILED: %d${RESET}\n" "$_fail"
        fi
        [[ "$_skip" -gt 0 ]] && printf "${YELLOW}SKIPPED: %d${RESET}\n" "$_skip"

        if [[ -s "$failures_jsonl" ]]; then
            echo ""
            bold "FAILURES:"
            while IFS= read -r entry; do
                local fname fmsg ffile
                fname=$(printf '%s' "$entry" | jq -r '.name' 2>/dev/null || echo "unknown")
                fmsg=$(printf '%s' "$entry"  | jq -r '.message' 2>/dev/null || echo "")
                ffile=$(printf '%s' "$entry" | jq -r '.file' 2>/dev/null || echo "")
                printf "  ${RED}%s${RESET}\n" "$fname"
                [[ -n "$fmsg" && "$fmsg" != "null" ]]   && printf "     %s\n" "$fmsg"
                [[ -n "$ffile" && "$ffile" != "null" ]]  && printf "     File: %s\n" "$ffile"
                echo ""
            done < <(jq -c '.[]' "$failures_jsonl" 2>/dev/null || true)
        fi

        echo ""
        if [[ "$_fail" -eq 0 ]]; then
            printf "${GREEN}Summary: All tests passed${RESET}\n"
        else
            printf "${RED}Summary: %d failure(s)${RESET}\n" "$_fail"
        fi

        rm -f "$failures_jsonl"
    fi

    return $test_exit_code
}

usage_test() {
    cat <<'EOF'
test --project <path> [--filter <expr>] [--configuration <config>] [--json]

  Run dotnet test on a project and parse results.

  Options:
    --project <path>         Path to .csproj or directory (required)
    --filter <expr>          dotnet test --filter expression
    --configuration <name>   Build configuration (default: Release)
    --json                   Output structured JSON

  JSON output shape:
    {project, duration_s, passed, failed, skipped, total, succeeded,
     failures: [{name, message, file}]}

  Handles multiple output formats:
    - xUnit multi-line (Passed: / Failed: / Skipped:)
    - VSTest single-line (Passed! - Failed: 0, Passed: N, ...)
    - Mocha-style (N passing / M failing)
EOF
}

# ---------------------------------------------------------------------------
# cmd_cleanup
# ---------------------------------------------------------------------------
# Usage: cleanup [--json]
#
# Kills orphaned VBCSCompiler and MSBuild processes.
# Conservative with dotnet: only kills compiler-related invocations.
# Does NOT kill dotnet server processes (watch, run, etc.).
cmd_cleanup() {
    local json_mode="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_mode="true"; shift ;;
            *) err "cleanup: unknown option: $1"; usage_cleanup; exit 1 ;;
        esac
    done

    local killed_count=0
    local killed_jsonl
    killed_jsonl=$(mktemp /tmp/dotnet_helpers_killed.XXXXXX)

    # VBCSCompiler: always a compiler daemon — always safe to kill
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        if ! kill -0 "$pid" 2>/dev/null; then continue; fi
        local mem process
        mem=$(mem_mb_of "$pid")
        process="VBCSCompiler"
        graceful_kill "$pid"
        jq -n --argjson pid "$pid" --arg process "$process" --argjson memory_mb "$mem" \
            '{pid:$pid,process:$process,memory_mb:$memory_mb}' >> "$killed_jsonl"
        killed_count=$(( killed_count + 1 ))
        [[ "$json_mode" != "true" ]] && ok "Killed VBCSCompiler PID=$pid (${mem}MB)"
    done < <(pids_of "VBCSCompiler")

    # MSBuild: always a build tool — always safe to kill
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        if ! kill -0 "$pid" 2>/dev/null; then continue; fi
        local mem process
        mem=$(mem_mb_of "$pid")
        process="MSBuild"
        graceful_kill "$pid"
        jq -n --argjson pid "$pid" --arg process "$process" --argjson memory_mb "$mem" \
            '{pid:$pid,process:$process,memory_mb:$memory_mb}' >> "$killed_jsonl"
        killed_count=$(( killed_count + 1 ))
        [[ "$json_mode" != "true" ]] && ok "Killed MSBuild PID=$pid (${mem}MB)"
    done < <(pids_of "MSBuild")

    # dotnet: conservative — only kill invocations that look like compiler/build
    # commands (build, publish, msbuild). Skip: run, watch, serve, test, ef, etc.
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        if ! kill -0 "$pid" 2>/dev/null; then continue; fi
        local cmd
        cmd=$(cmd_of "$pid")
        # Only kill if the dotnet invocation is clearly a build/compile operation
        if ! printf '%s' "$cmd" | grep -qE 'dotnet.*(build|publish|msbuild|restore|pack)\b'; then
            continue
        fi
        local mem process
        mem=$(mem_mb_of "$pid")
        process="dotnet-build"
        graceful_kill "$pid"
        jq -n --argjson pid "$pid" --arg process "$process" --argjson memory_mb "$mem" \
            '{pid:$pid,process:$process,memory_mb:$memory_mb}' >> "$killed_jsonl"
        killed_count=$(( killed_count + 1 ))
        [[ "$json_mode" != "true" ]] && ok "Killed dotnet-build PID=$pid (${mem}MB)"
    done < <(pids_of "dotnet")

    if [[ "$json_mode" == "true" ]]; then
        local killed_json="[]"
        if [[ -s "$killed_jsonl" ]]; then
            killed_json=$(jq -s '.' "$killed_jsonl")
        fi
        rm -f "$killed_jsonl"
        jq -n \
            --argjson killed_count "$killed_count" \
            --argjson killed       "$killed_json" \
            '{killed_count:$killed_count,killed:$killed}'
    else
        rm -f "$killed_jsonl"
        echo ""
        if [[ $killed_count -eq 0 ]]; then
            ok "Nothing to kill — no orphaned compiler processes found."
        else
            ok "Killed $killed_count orphaned compiler process(es)."
        fi
        echo ""
    fi
}

usage_cleanup() {
    cat <<'EOF'
cleanup [--json]

  Kill orphaned .NET compiler processes (VBCSCompiler, MSBuild, dotnet build/publish).

  Conservative: dotnet processes that are not clearly build/compile operations
  (e.g. dotnet run, dotnet watch, dotnet test) are NOT killed.

  Options:
    --json   Output structured JSON

  JSON output shape:
    {killed_count, killed: [{pid, process, memory_mb}]}
EOF
}

# ---------------------------------------------------------------------------
# cmd_analyze_errors
# ---------------------------------------------------------------------------
# Usage: analyze-errors <file> [--json]
#
# Read build output from a file and categorize errors (no dotnet invocation).
cmd_analyze_errors() {
    local file=""
    local json_mode="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_mode="true"; shift ;;
            -*)     err "analyze-errors: unknown option: $1"; usage_analyze; exit 1 ;;
            *)
                if [[ -z "$file" ]]; then
                    file="$1"
                    shift
                else
                    err "analyze-errors: unexpected argument: $1"
                    usage_analyze
                    exit 1
                fi
                ;;
        esac
    done

    if [[ -z "$file" ]]; then
        err "analyze-errors: <file> is required"
        usage_analyze
        exit 1
    fi

    if [[ ! -f "$file" ]]; then
        err "analyze-errors: file not found: $file"
        exit 1
    fi

    if [[ "$json_mode" == "true" ]]; then
        # No live dotnet invocation, so build_exit_code is null. We use 0 here
        # so the non_compiler_failure flag stays false; callers can interpret
        # build_exit_code: null as "not applicable" per the spec.
        JSON_OUTPUT=true build_output_to_json "$file" "$file" "0"
    else
        build_output_human "$file" "$file" "0" || true
    fi
}

usage_analyze() {
    cat <<'EOF'
analyze-errors <file> [--json]

  Parse build output from a previously saved file and categorize errors.
  Does not invoke dotnet — reads the file as-is.

  Arguments:
    <file>    Path to a file containing dotnet build output

  Options:
    --json    Output structured JSON

  JSON output shape: same as `build` but build_exit_code is 0 (not applicable).
EOF
}

# ---------------------------------------------------------------------------
# Top-level usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
dotnet-helpers.sh — .NET build/test/cleanup helper

Usage: dotnet-helpers.sh <command> [options]

Commands:
  build           Run dotnet build, parse and categorize errors
  test            Run dotnet test, parse results
  cleanup         Kill orphaned VBCSCompiler and MSBuild processes
  analyze-errors  Parse a saved build output file, categorize errors

Run `dotnet-helpers.sh <command> --help` for command-specific options.
EOF
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        build)
            # Support --help within commands
            for arg in "$@"; do
                if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
                    usage_build; exit 0
                fi
            done
            cmd_build "$@"
            ;;
        test)
            for arg in "$@"; do
                if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
                    usage_test; exit 0
                fi
            done
            cmd_test "$@"
            ;;
        cleanup)
            for arg in "$@"; do
                if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
                    usage_cleanup; exit 0
                fi
            done
            cmd_cleanup "$@"
            ;;
        analyze-errors)
            for arg in "$@"; do
                if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
                    usage_analyze; exit 0
                fi
            done
            cmd_analyze_errors "$@"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            err "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"

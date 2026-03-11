#!/usr/bin/env bash
# Test suite for MCPB manifest validation
# Requires: jq, bash 4+
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
PASS=0
FAIL=0
ERRORS=""

pass() {
	PASS=$((PASS + 1))
	printf '\033[0;32mPASS\033[0m %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	ERRORS+="  FAIL: $1 — $2\n"
	printf '\033[0;31mFAIL\033[0m %s — %s\n' "$1" "$2"
}

# ── Manifest validation function ──
# Mirrors the validation logic from the workflow
validate_manifest() {
	local manifest="$1"
	local errors=""

	if [ ! -f "$manifest" ]; then
		echo "FILE_NOT_FOUND"
		return 1
	fi

	# Check required fields
	for field in \
		'.manifest_version' '.name' '.version' \
		'.description' '.author.name' \
		'.server.type' '.server.entry_point'; do
		value=$(jq -r "$field // empty" "$manifest")
		if [ -z "$value" ]; then
			errors+="Missing: ${field}\n"
		fi
	done

	# Validate server type
	server_type=$(jq -r '.server.type // empty' \
		"$manifest")
	if [ -n "$server_type" ]; then
		case "$server_type" in
		node | python | binary | uv) ;;
		*) errors+="Invalid type: ${server_type}\n" ;;
		esac
	fi

	# Validate semver
	version=$(jq -r '.version // empty' "$manifest")
	if [ -n "$version" ]; then
		semver='^[0-9]+\.[0-9]+\.[0-9]+'
		semver+='(-[a-zA-Z0-9.]+)?'
		semver+='(\+[a-zA-Z0-9.]+)?$'
		if ! echo "$version" | grep -qE "$semver"; then
			errors+="Invalid semver: ${version}\n"
		fi
	fi

	# UV must use manifest_version 0.4
	if [ "$server_type" = "uv" ]; then
		mv=$(jq -r '.manifest_version' "$manifest")
		if [ "$mv" != "0.4" ]; then
			errors+="UV requires version 0.4\n"
		fi
	fi

	# Validate platforms
	platforms=$(jq -r \
		'.compatibility.platforms[]? // empty' \
		"$manifest" 2>/dev/null)
	for p in $platforms; do
		case "$p" in
		darwin | win32 | linux) ;;
		*) errors+="Invalid platform: ${p}\n" ;;
		esac
	done

	# Validate user_config types
	config_types=$(jq -r '
    .user_config // {} |
    to_entries[] |
    .value.type // empty
  ' "$manifest" 2>/dev/null || true)
	for t in $config_types; do
		case "$t" in
		string | number | boolean | directory | file) ;;
		*) errors+="Invalid config type: ${t}\n" ;;
		esac
	done

	# Validate variable substitution refs
	used_vars=$(jq -r '
    [
      .server.mcp_config.args[]?,
      (
        .server.mcp_config.env // {}
        | to_entries[]
        | .value
      )
    ] |
    map(select(test("\\$\\{user_config\\."))) |
    map(
      capture(
        "\\$\\{user_config\\.(?<k>[^}]+)\\}"
      ) | .k
    ) | unique[]
  ' "$manifest" 2>/dev/null || true)

	for var in $used_vars; do
		has=$(jq -r \
			".user_config.\"$var\" // empty" \
			"$manifest")
		if [ -z "$has" ]; then
			errors+="Undefined ref: ${var}\n"
		fi
	done

	# Check duplicate tool names
	dups=$(jq -r '
    [.tools[]?.name] |
    group_by(.) |
    map(select(length > 1)) |
    .[0][0] // empty
  ' "$manifest" 2>/dev/null)
	if [ -n "$dups" ]; then
		errors+="Duplicate tool: ${dups}\n"
	fi

	if [ -n "$errors" ]; then
		printf "%b" "$errors"
		return 1
	fi

	return 0
}

# ── Test cases ──

echo ""
printf '\033[1;33m=== MCPB Manifest Validation Tests ===\033[0m\n'
echo ""

# --- Valid manifests ---

echo "-- Valid manifests --"

if validate_manifest \
	"$FIXTURES/valid-manifest.json" \
	>/dev/null 2>&1; then
	pass "valid-manifest.json passes validation"
else
	fail "valid-manifest.json" \
		"should pass but failed"
fi

if validate_manifest \
	"$FIXTURES/valid-uv-manifest.json" \
	>/dev/null 2>&1; then
	pass "valid-uv-manifest.json passes validation"
else
	fail "valid-uv-manifest.json" \
		"should pass but failed"
fi

if validate_manifest \
	"$FIXTURES/valid-binary-manifest.json" \
	>/dev/null 2>&1; then
	pass "valid-binary-manifest.json passes validation"
else
	fail "valid-binary-manifest.json" \
		"should pass but failed"
fi

echo ""
echo "-- Invalid manifests --"

# --- Missing required fields ---
if validate_manifest \
	"$FIXTURES/invalid-missing-fields.json" \
	>/dev/null 2>&1; then
	fail "invalid-missing-fields.json" \
		"should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-missing-fields.json" \
		2>&1 || true)
	if echo "$output" | grep -q "Missing:"; then
		pass "missing fields detected correctly"
	else
		fail "invalid-missing-fields.json" \
			"wrong error type"
	fi
fi

# --- Bad semver ---
if validate_manifest \
	"$FIXTURES/invalid-bad-version.json" \
	>/dev/null 2>&1; then
	fail "invalid-bad-version.json" \
		"should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-bad-version.json" \
		2>&1 || true)
	if echo "$output" | grep -q "Invalid semver"; then
		pass "invalid semver detected correctly"
	else
		fail "invalid-bad-version.json" \
			"wrong error type"
	fi
fi

# --- Bad server type ---
if validate_manifest \
	"$FIXTURES/invalid-bad-type.json" \
	>/dev/null 2>&1; then
	fail "invalid-bad-type.json" \
		"should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-bad-type.json" \
		2>&1 || true)
	if echo "$output" | grep -q "Invalid type"; then
		pass "invalid server type detected correctly"
	else
		fail "invalid-bad-type.json" \
			"wrong error type"
	fi
fi

# --- UV with wrong manifest version ---
if validate_manifest \
	"$FIXTURES/invalid-uv-wrong-version.json" \
	>/dev/null 2>&1; then
	fail "invalid-uv-wrong-version.json" \
		"should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-uv-wrong-version.json" \
		2>&1 || true)
	if echo "$output" |
		grep -q "UV requires version 0.4"; then
		pass "UV version mismatch detected correctly"
	else
		fail "invalid-uv-wrong-version.json" \
			"wrong error type"
	fi
fi

# --- Duplicate tool names ---
if validate_manifest \
	"$FIXTURES/invalid-duplicate-tools.json" \
	>/dev/null 2>&1; then
	fail "invalid-duplicate-tools.json" \
		"should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-duplicate-tools.json" \
		2>&1 || true)
	if echo "$output" | grep -q "Duplicate tool"; then
		pass "duplicate tools detected correctly"
	else
		fail "invalid-duplicate-tools.json" \
			"wrong error type"
	fi
fi

# --- Bad platform ---
if validate_manifest \
	"$FIXTURES/invalid-bad-platform.json" \
	>/dev/null 2>&1; then
	fail "invalid-bad-platform.json" \
		"should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-bad-platform.json" \
		2>&1 || true)
	if echo "$output" |
		grep -q "Invalid platform"; then
		pass "invalid platform detected correctly"
	else
		fail "invalid-bad-platform.json" \
			"wrong error type"
	fi
fi

# --- Undefined config reference ---
if validate_manifest \
	"$FIXTURES/invalid-undefined-config-ref.json" \
	>/dev/null 2>&1; then
	fail "invalid-undefined-config-ref.json" \
		"should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-undefined-config-ref.json" \
		2>&1 || true)
	if echo "$output" | grep -q "Undefined ref"; then
		pass "undefined config ref detected correctly"
	else
		fail "invalid-undefined-config-ref.json" \
			"wrong error type: $output"
	fi
fi

# --- Bad config type ---
if validate_manifest \
	"$FIXTURES/invalid-bad-config-type.json" \
	>/dev/null 2>&1; then
	fail "invalid-bad-config-type.json" \
		"should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-bad-config-type.json" \
		2>&1 || true)
	if echo "$output" |
		grep -q "Invalid config type"; then
		pass "invalid config type detected correctly"
	else
		fail "invalid-bad-config-type.json" \
			"wrong error type"
	fi
fi

# --- JSON parse test ---
echo ""
echo "-- JSON structure tests --"

for fixture in "$FIXTURES"/*.json; do
	fname=$(basename "$fixture")
	if jq empty "$fixture" 2>/dev/null; then
		pass "$fname is valid JSON"
	else
		fail "$fname" "invalid JSON"
	fi
done

# --- Workflow YAML tests ---
echo ""
echo "-- Workflow YAML tests --"

WORKFLOW="$SCRIPT_DIR/../.github/workflows/mcp-bundle.yml"
ACTION="$SCRIPT_DIR/../action.yml"

# Check workflow file exists
if [ -f "$WORKFLOW" ]; then
	pass "mcp-bundle.yml exists"
else
	fail "mcp-bundle.yml" "file not found"
fi

# Check action.yml exists
if [ -f "$ACTION" ]; then
	pass "action.yml exists"
else
	fail "action.yml" "file not found"
fi

# Validate workflow has required inputs
if [ -f "$WORKFLOW" ]; then
	for input in \
		source-files manifest-path config-files \
		additional-artifacts node-version \
		build-command test-command bundle-name \
		upload-artifact create-release-asset \
		mcpb-version; do
		if grep -q "      ${input}:" "$WORKFLOW"; then
			pass "workflow has input: $input"
		else
			fail "workflow input" \
				"missing input: $input"
		fi
	done

	# Validate workflow has required outputs
	for output in \
		bundle-path bundle-sha256 manifest-valid; do
		if grep -q "      ${output}:" "$WORKFLOW"; then
			pass "workflow has output: $output"
		else
			fail "workflow output" \
				"missing output: $output"
		fi
	done
fi

# Check action.yml has required fields
if [ -f "$ACTION" ]; then
	for field in name description author branding; do
		if grep -q "^${field}:" "$ACTION"; then
			pass "action.yml has field: $field"
		else
			fail "action.yml" "missing field: $field"
		fi
	done
fi

# --- Plugin structure tests ---
echo ""
echo "-- Plugin structure tests --"

PLUGIN_JSON="$SCRIPT_DIR/../.claude-plugin/plugin.json"
if [ -f "$PLUGIN_JSON" ]; then
	pass ".claude-plugin/plugin.json exists"
	if jq empty "$PLUGIN_JSON" 2>/dev/null; then
		pass "plugin.json is valid JSON"
	else
		fail "plugin.json" "invalid JSON"
	fi
	PLUGIN_NAME=$(jq -r '.name // empty' "$PLUGIN_JSON")
	if [ -n "$PLUGIN_NAME" ]; then
		pass "plugin.json has name: $PLUGIN_NAME"
	else
		fail "plugin.json" "missing required name field"
	fi
else
	fail ".claude-plugin/plugin.json" "file not found"
fi

# --- Skill file tests ---
echo ""
echo "-- Skill file tests --"

SKILL="$SCRIPT_DIR/../skills/mcpb/SKILL.md"
if [ -f "$SKILL" ]; then
	pass "skills/mcpb/SKILL.md exists"

	# Check frontmatter
	if head -1 "$SKILL" | grep -q "^---"; then
		pass "skill has YAML frontmatter"
	else
		fail "skill" "missing YAML frontmatter"
	fi

	# Check required frontmatter fields
	for field in name description user_invocable; do
		if grep -q "^${field}:" "$SKILL"; then
			pass "skill has frontmatter: $field"
		else
			fail "skill frontmatter" "missing: $field"
		fi
	done

	# Check key content sections
	for section in \
		"Step 1" "Step 2" "Step 3" \
		"Step 4" "Step 5" "Step 6" "Step 7"; do
		if grep -q "$section" "$SKILL"; then
			pass "skill has section: $section"
		else
			fail "skill content" \
				"missing section: $section"
		fi
	done
else
	fail "skills/mcpb/SKILL.md" "file not found"
fi

# --- Example workflows ---
echo ""
echo "-- Example workflow tests --"

EXAMPLES="$SCRIPT_DIR/../examples"
for example in \
	minimal-caller.yml \
	standard-caller.yml \
	advanced-caller.yml \
	binary-caller.yml; do
	if [ -f "$EXAMPLES/$example" ]; then
		pass "example exists: $example"
		if grep -q "workflow_call\|uses:" \
			"$EXAMPLES/$example"; then
			pass "$example references reusable workflow"
		else
			fail "$example" \
				"no workflow reference found"
		fi
	else
		fail "example" "missing: $example"
	fi
done

# ── Summary ──
echo ""
printf '\033[1;33m=== Results ===\033[0m\n'
TOTAL=$((PASS + FAIL))
printf 'Total: %d  ' "$TOTAL"
printf '\033[0;32mPassed: %d\033[0m  ' "$PASS"
printf '\033[0;31mFailed: %d\033[0m\n' "$FAIL"

if [ "$FAIL" -gt 0 ]; then
	echo ""
	printf '\033[0;31mFailures:\033[0m\n'
	printf "%b" "$ERRORS"
	exit 1
fi

echo ""
printf '\033[0;32mAll tests passed!\033[0m\n'
exit 0

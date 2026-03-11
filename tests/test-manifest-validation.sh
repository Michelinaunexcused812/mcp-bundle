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

	# Check tool entries have both name and description
	tool_missing=$(jq -r '
    .tools[]? |
    select((.name // "") == "" or (.description // "") == "") |
    .name // "(unnamed)"
  ' "$manifest" 2>/dev/null || true)
	if [ -n "$tool_missing" ]; then
		errors+="Tool missing name or description: ${tool_missing}\n"
	fi

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

# --- Tool missing description ---
if validate_manifest \
	"$FIXTURES/invalid-tool-missing-description.json" \
	>/dev/null 2>&1; then
	fail "invalid-tool-missing-description.json" \
		"should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-tool-missing-description.json" \
		2>&1 || true)
	if echo "$output" |
		grep -q "Tool missing name or description"; then
		pass "tool missing description detected correctly"
	else
		fail "invalid-tool-missing-description.json" \
			"wrong error type: $output"
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
		mcpb-version runs-on; do
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

# --- Review remediation tests ---
echo ""
echo "-- Review remediation tests --"

# workflow runs-on defaults to ubuntu-latest
if grep -q "default: ubuntu-latest" "$WORKFLOW"; then
	pass "workflow runs-on defaults to ubuntu-latest"
else
	fail "workflow runs-on" \
		"missing default ubuntu-latest"
fi

# workflow has .mcpbignore step
if grep -q "Apply .mcpbignore exclusions" "$WORKFLOW"; then
	pass "workflow has .mcpbignore step"
else
	fail "workflow" "missing .mcpbignore step"
fi

# action.yml reads .mcpbignore
if grep -q "mcpbignore" "$ACTION"; then
	pass "action.yml reads .mcpbignore"
else
	fail "action.yml" "missing .mcpbignore support"
fi

# action.yml entry_point is warning not error
if grep -q "::warning::Entry point" "$ACTION"; then
	pass "action.yml entry_point is warning"
else
	fail "action.yml" \
		"entry_point should be warning"
fi

# workflow entry_point is still error
if grep -q 'Entry point file not found' "$WORKFLOW"; then
	pass "workflow entry_point is still error"
else
	fail "workflow" \
		"entry_point should remain error"
fi

# ci.yml exists
CI_WORKFLOW="$SCRIPT_DIR/../.github/workflows/ci.yml"
if [ -f "$CI_WORKFLOW" ]; then
	pass "ci.yml exists"
else
	fail "ci.yml" "file not found"
fi

# ci.yml runs test suite
if [ -f "$CI_WORKFLOW" ] &&
	grep -q "test-manifest-validation" "$CI_WORKFLOW"; then
	pass "ci.yml runs test suite"
else
	fail "ci.yml" \
		"missing test-manifest-validation ref"
fi

# --- Server-type auto-include tests ---
echo ""
echo "-- Server-type auto-include tests --"

# workflow auto-includes requirements.txt for python
if grep -q 'requirements.txt.*python' "$WORKFLOW"; then
	pass "workflow auto-includes requirements.txt for python"
else
	fail "workflow" \
		"missing requirements.txt auto-include"
fi

# workflow auto-includes pyproject.toml for uv
if grep -q 'pyproject.toml.*uv' "$WORKFLOW"; then
	pass "workflow auto-includes pyproject.toml for uv"
else
	fail "workflow" \
		"missing pyproject.toml auto-include"
fi

# workflow auto-includes LICENSE for all types
if grep -q 'LICENSE.*STAGING' "$WORKFLOW"; then
	pass "workflow auto-includes LICENSE"
else
	fail "workflow" \
		"missing LICENSE auto-include"
fi

# --- New valid fixture tests ---
echo ""
echo "-- Extended valid fixture tests --"

# Python manifest
if validate_manifest \
	"$FIXTURES/valid-python-manifest.json" \
	>/dev/null 2>&1; then
	pass "valid-python-manifest.json passes validation"
else
	fail "valid-python-manifest.json" \
		"should pass but failed"
fi

# Pre-release semver (1.0.0-beta.1)
if validate_manifest \
	"$FIXTURES/valid-semver-prerelease.json" \
	>/dev/null 2>&1; then
	pass "pre-release semver 1.0.0-beta.1 passes validation"
else
	fail "valid-semver-prerelease.json" \
		"pre-release semver should pass but failed"
fi

# Build-metadata semver (1.0.0+build.42)
if validate_manifest \
	"$FIXTURES/valid-semver-buildmeta.json" \
	>/dev/null 2>&1; then
	pass "build-metadata semver 1.0.0+build.42 passes validation"
else
	fail "valid-semver-buildmeta.json" \
		"build-metadata semver should pass but failed"
fi

# No tools key at all
if validate_manifest \
	"$FIXTURES/valid-no-tools.json" \
	>/dev/null 2>&1; then
	pass "manifest with no tools key passes validation"
else
	fail "valid-no-tools.json" \
		"no tools key should pass but failed"
fi

# Empty tools array
if validate_manifest \
	"$FIXTURES/valid-empty-tools.json" \
	>/dev/null 2>&1; then
	pass "manifest with empty tools array passes validation"
else
	fail "valid-empty-tools.json" \
		"empty tools array should pass but failed"
fi

# All valid user_config types (string, number, boolean, directory, file)
if validate_manifest \
	"$FIXTURES/valid-all-config-types.json" \
	>/dev/null 2>&1; then
	pass "all valid user_config types pass validation"
else
	fail "valid-all-config-types.json" \
		"all config types should pass but failed"
fi

# Both args and env config refs defined
if validate_manifest \
	"$FIXTURES/valid-partial-config-refs.json" \
	>/dev/null 2>&1; then
	pass "config refs in both args and env pass validation"
else
	fail "valid-partial-config-refs.json" \
		"defined config refs should pass but failed"
fi

# --- Extended invalid fixture tests ---
echo ""
echo "-- Extended invalid fixture tests --"

# v-prefixed version (v1.0.0)
if validate_manifest \
	"$FIXTURES/invalid-version-with-v-prefix.json" \
	>/dev/null 2>&1; then
	fail "invalid-version-with-v-prefix.json" \
		"v-prefix version should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-version-with-v-prefix.json" \
		2>&1 || true)
	if echo "$output" | grep -q "Invalid semver"; then
		pass "v-prefixed version rejected correctly"
	else
		fail "invalid-version-with-v-prefix.json" \
			"wrong error type: $output"
	fi
fi

# Empty string name (not null — jq returns empty for empty string)
if validate_manifest \
	"$FIXTURES/invalid-empty-name.json" \
	>/dev/null 2>&1; then
	fail "invalid-empty-name.json" \
		"empty name should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-empty-name.json" \
		2>&1 || true)
	if echo "$output" | grep -q "Missing:"; then
		pass "empty name string rejected correctly"
	else
		fail "invalid-empty-name.json" \
			"wrong error type: $output"
	fi
fi

# Multiple missing required fields at once
if validate_manifest \
	"$FIXTURES/invalid-multiple-missing-fields.json" \
	>/dev/null 2>&1; then
	fail "invalid-multiple-missing-fields.json" \
		"multiple missing fields should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-multiple-missing-fields.json" \
		2>&1 || true)
	missing_count=$(echo "$output" |
		grep -c "Missing:" || true)
	if [ "$missing_count" -ge 3 ]; then
		pass "multiple missing fields reported ($missing_count errors)"
	else
		fail "invalid-multiple-missing-fields.json" \
			"expected >=3 Missing: errors, got $missing_count"
	fi
fi

# Multiple undefined config refs in args and env
if validate_manifest \
	"$FIXTURES/invalid-multiple-config-refs.json" \
	>/dev/null 2>&1; then
	fail "invalid-multiple-config-refs.json" \
		"multiple undefined refs should fail but passed"
else
	output=$(validate_manifest \
		"$FIXTURES/invalid-multiple-config-refs.json" \
		2>&1 || true)
	ref_count=$(echo "$output" |
		grep -c "Undefined ref:" || true)
	if [ "$ref_count" -ge 2 ]; then
		pass "multiple undefined config refs reported ($ref_count errors)"
	else
		fail "invalid-multiple-config-refs.json" \
			"expected >=2 Undefined ref: errors, got $ref_count"
	fi
fi

# --- Security: eval usage ---
echo ""
echo "-- Security audit tests --"

# workflow build/test commands use bash -c (not eval)
# shellcheck disable=SC2016
if grep -q 'bash -c "\$BUILD_CMD"' "$WORKFLOW"; then
	pass "workflow build-command uses bash -c (not eval)"
else
	fail "workflow security" \
		"build-command should use bash -c not eval"
fi
# shellcheck disable=SC2016
if grep -q 'bash -c "\$TEST_CMD"' "$WORKFLOW"; then
	pass "workflow test-command uses bash -c (not eval)"
else
	fail "workflow security" \
		"test-command should use bash -c not eval"
fi

# action.yml zip excludes use bash array (not eval + string concatenation)
if grep -q 'EXCLUDE_ARGS\+=\|EXCLUDES=(' "$ACTION"; then
	pass "action.yml zip excludes use bash array (no eval injection risk)"
else
	fail "action.yml security" \
		"zip excludes should use bash array, not eval+string"
fi

# Workflow: GH_TOKEN is sourced from github.token (not a user input)
# shellcheck disable=SC2016
if grep -q 'GH_TOKEN: \${{ github.token }}' "$WORKFLOW"; then
	pass "workflow GH_TOKEN sourced from github.token (not user input)"
else
	fail "workflow security" \
		"GH_TOKEN not sourced from github.token"
fi

# action.yml: GH_TOKEN is sourced from github.token (not a user input)
# shellcheck disable=SC2016
if grep -q 'GH_TOKEN: \${{ github.token }}' "$ACTION"; then
	pass "action.yml GH_TOKEN sourced from github.token (not user input)"
else
	fail "action.yml security" \
		"GH_TOKEN not sourced from github.token"
fi

# .mcpbignore pattern handling does not allow absolute paths to escape staging
if grep -q 'find.*STAGING.*-name' "$WORKFLOW"; then
	pass "workflow .mcpbignore uses find -name (confined to staging dir)"
else
	fail "workflow security" \
		".mcpbignore processing may not be confined to staging dir"
fi

# node_modules copied to staging (not skipped) for node server type
if grep -q 'node_modules.*STAGING\|cp.*node_modules.*STAGING' "$WORKFLOW" ||
	grep -q 'node_modules.*staging' "$WORKFLOW"; then
	pass "workflow copies node_modules to staging for node type"
else
	fail "workflow capability" \
		"node_modules not copied to staging"
fi

# --- Workflow: mcpb-version input injection safety ---
# mcpb-version is passed as env var to shell before npm install
if grep -q 'MCPB_VER.*mcpb-version\|mcpb-version.*MCPB_VER' "$WORKFLOW"; then
	pass "workflow mcpb-version passed via env var (not inline)"
else
	fail "workflow security" \
		"mcpb-version not isolated via env var before npm install"
fi

# --- Workflow: sha256sum availability ---
# Workflow uses sha256sum (GNU coreutils - linux specific)
# This is fine on ubuntu-latest but may fail on macOS
if grep -q 'sha256sum' "$WORKFLOW"; then
	pass "workflow uses sha256sum for checksums"
fi
# action.yml must have portable sha256 fallback (sha256sum || shasum -a 256)
if grep -q 'sha256sum' "$ACTION" &&
	grep -q 'shasum' "$ACTION"; then
	pass "action.yml has portable sha256 fallback (sha256sum || shasum)"
else
	fail "action.yml capability" \
		"action.yml missing portable sha256 fallback for macOS runners"
fi

# --- Workflow: cleanup step runs on always() ---
if grep -q "if: always()" "$WORKFLOW"; then
	pass "workflow has cleanup step with always() condition"
else
	fail "workflow" \
		"missing cleanup step with always() condition"
fi

# --- Workflow: cleanup guards empty STAGING ---
if grep -q '\-n.*STAGING.*rm\|STAGING.*&&.*rm' "$WORKFLOW"; then
	pass "workflow cleanup guards empty STAGING variable"
else
	fail "workflow security" \
		"rm -rf STAGING not guarded against empty value"
fi

# --- Workflow: globstar enabled for ** patterns ---
if grep -q 'shopt -s globstar' "$WORKFLOW"; then
	pass "workflow enables globstar for ** glob expansion"
else
	fail "workflow capability" \
		"missing shopt -s globstar for ** patterns"
fi

# --- Capability: node_modules included for node type ---
if grep -q 'SERVER_TYPE.*node\|node.*SERVER_TYPE' "$WORKFLOW" &&
	grep -q 'node_modules' "$WORKFLOW"; then
	pass "workflow conditionally includes node_modules for node type"
else
	fail "workflow capability" \
		"node_modules not conditionally included for node type"
fi

# --- Capability: icon.png support ---
if grep -q '\.icon\|icon.*STAGING\|ICON' "$WORKFLOW"; then
	pass "workflow supports icon file from manifest"
else
	fail "workflow capability" \
		"workflow missing icon.png support"
fi

# --- Capability: checkout step present in reusable workflow ---
if grep -q 'actions/checkout' "$WORKFLOW"; then
	pass "reusable workflow includes checkout step"
else
	fail "workflow capability" \
		"missing checkout step"
fi

# --- Skill: security constraints documented ---
if grep -q 'No shell injection\|shell injection' "$SKILL"; then
	pass "skill documents shell injection constraint"
else
	fail "skill security" \
		"skill missing shell injection constraint"
fi

# --- Skill: stdio transport constraint documented ---
if grep -q 'stdio transport ONLY\|stdio.*ONLY' "$SKILL"; then
	pass "skill documents stdio transport constraint"
else
	fail "skill capability" \
		"skill missing stdio transport constraint"
fi

# --- Skill: stderr logging constraint documented ---
if grep -q 'stderr.*logging\|logging.*stderr' "$SKILL"; then
	pass "skill documents stderr logging constraint"
else
	fail "skill capability" \
		"skill missing stderr logging constraint"
fi

# --- Skill: idempotency constraint documented ---
if grep -q '[Ii]dempotent' "$SKILL"; then
	pass "skill documents idempotency constraint"
else
	fail "skill capability" \
		"skill missing idempotency constraint"
fi

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

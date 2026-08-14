#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
OPIAI_EXTENSION="${REPO_ROOT}/extensions/opiai-uboot.sh"
BOARD_CONFIG="${REPO_ROOT}/config/boards/orangepiaipro20t.csc"
BOARD_8T_CONFIG="${REPO_ROOT}/config/boards/orangepiaipro8t.csc"
FAMILY_CONFIG="${REPO_ROOT}/config/sources/families/ascend310b.conf"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	local expected="${1}"
	local actual="${2}"
	local context="${3:-}"
	[[ "${actual}" == "${expected}" ]] || fail "${context}: expected '${expected}', got '${actual}'"
}

assert_file_contains() {
	local file_path="${1}"
	local pattern="${2}"
	grep -Fq -- "${pattern}" "${file_path}" || fail "${file_path} missing '${pattern}'"
}

assert_file_not_contains() {
	local file_path="${1}"
	local pattern="${2}"
	if grep -Fq -- "${pattern}" "${file_path}"; then
		fail "${file_path} unexpectedly contains '${pattern}'"
	fi
}

display_alert() { :; }

exit_with_error() {
	printf 'exit_with_error: %s\n' "$*" >&2
	return 1
}

run_host_command_logged() {
	if [[ "$#" -eq 1 ]]; then
		bash -euo pipefail -c "$1"
	else
		"$@"
	fi
}

fetch_from_repo() { :; }
install_deb_chroot() { :; }

# shellcheck disable=SC1090 # Resolved dynamically from this repository's root.
source "${OPIAI_EXTENSION}"

cleanup_paths=()
cleanup() {
	local path
	for path in "${cleanup_paths[@]:-}"; do
		rm -rf "${path}"
	done
}
trap cleanup EXIT

new_tmpdir() {
	local temporary_dir
	temporary_dir="$(mktemp -d)"
	cleanup_paths+=("${temporary_dir}")
	echo "${temporary_dir}"
}

make_arm64_image() {
	local image_file="${1}"
	local size="${2:-4096}"
	truncate -s "${size}" "${image_file}"
	printf '\x41\x52\x4d\x64' | dd "of=${image_file}" bs=1 seek=$((0x38)) conv=notrunc status=none
}

test_accepts_standard_arm64_image() {
	local temporary_dir source_image
	temporary_dir="$(new_tmpdir)"
	source_image="${temporary_dir}/Image.raw"
	make_arm64_image "${source_image}"
	opiai__validate_standard_linux_image "${source_image}"
	assert_eq "41524d64" "$(opiai__arm64_image_magic "${source_image}")" "raw Image magic"
}

test_rejects_hboot2_wrapped_image() {
	local temporary_dir payload wrapper
	temporary_dir="$(new_tmpdir)"
	payload="${temporary_dir}/payload"
	wrapper="${temporary_dir}/Image"
	make_arm64_image "${payload}" 8192
	truncate -s $((0x2100)) "${wrapper}"
	dd "if=${payload}" "of=${wrapper}" bs=4M oflag=append conv=notrunc status=none
	if opiai__validate_standard_linux_image "${wrapper}"; then
		fail "hboot2-wrapped kernel Image was accepted as a standard Image"
	fi
}

test_rejects_unknown_kernel_image() {
	local temporary_dir source_image
	temporary_dir="$(new_tmpdir)"
	source_image="${temporary_dir}/invalid"
	truncate -s 16384 "${source_image}"
	if opiai__validate_standard_linux_image "${source_image}"; then
		fail "invalid kernel Image was accepted"
	fi
}

test_latest_release_uses_resolved_cache_directory() {
	local temporary_dir tag
	temporary_dir="$(new_tmpdir)"
	export SRC="${temporary_dir}/src"
	export OPIAI_KERNEL_VERSION="latest"
	unset OPIAI_LOCAL_OUTPUT_DIR OPIAI_RESOLVED_KERNEL_VERSION
	# shellcheck disable=SC2329 # Called indirectly by the sourced extension.
	curl() { printf '{"tag_name":"6.18.39"}\n'; }
	# shellcheck disable=SC2329 # Called indirectly by the sourced extension.
	jq() { sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p'; }
	tag="$(opiai__resolve_release_tag)"
	assert_eq "6.18.39" "${tag}" "resolved release"
	assert_eq "${SRC}/cache/sources/opiai/releases/6.18.39" "$(opiai__release_download_dir "${tag}")" "resolved cache directory"
	unset -f curl jq
}

test_hboot2_region_limit() {
	assert_eq "$((31 * 1024 * 1024))" "$(opiai__hboot2_region_max_bytes 32)" "hboot2 region size"
}

test_write_uboot_uses_one_mib_offset() {
	local temporary_dir source_dir raw_image target_image marker
	temporary_dir="$(new_tmpdir)"
	source_dir="${temporary_dir}/source"
	raw_image="${source_dir}/hboot2-uboot.raw"
	target_image="${temporary_dir}/disk.raw"
	mkdir -p "${source_dir}"
	marker="hboot2-uboot-test"
	printf '%s' "${marker}" > "${raw_image}"
	truncate -s 40M "${target_image}"
	write_uboot_platform "${source_dir}" "${target_image}"
	assert_eq "${marker}" "$(dd "if=${target_image}" bs=1 skip=$((1024 * 1024)) count=${#marker} status=none)" "written U-Boot marker"
}

test_new_boot_configuration_is_standard() {
	assert_file_contains "${BOARD_CONFIG}" 'BOOTCONFIG="ascend310b_hboot2_defconfig"'
	assert_file_contains "${BOARD_CONFIG}" 'IMAGE_PARTITION_TABLE="gpt"'
	assert_file_contains "${BOARD_CONFIG}" 'SRC_EXTLINUX="yes"'
	assert_file_contains "${BOARD_CONFIG}" 'OFFSET=32'
	assert_file_contains "${BOARD_CONFIG}" 'BOOT_FDT_FILE="hi1910b/hi1910B-orangepiaipro20t.dtb"'
	assert_file_contains "${BOARD_8T_CONFIG}" 'BOOTCONFIG="ascend310b_hboot2_defconfig"'
	assert_file_contains "${BOARD_8T_CONFIG}" 'IMAGE_PARTITION_TABLE="gpt"'
	assert_file_contains "${BOARD_8T_CONFIG}" 'SRC_EXTLINUX="yes"'
	assert_file_contains "${BOARD_8T_CONFIG}" 'OFFSET=32'
	assert_file_contains "${BOARD_8T_CONFIG}" 'BOOT_FDT_FILE="hi1910b/hi1910B-orangepiaipro8t.dtb"'
	assert_file_contains "${FAMILY_CONFIG}" 'enable_extension "opiai-uboot"'
	assert_file_contains "${FAMILY_CONFIG}" 'BOOTSOURCE="https://github.com/HwHiAiUser/u-boot"'
	assert_file_contains "${FAMILY_CONFIG}" 'BOOTBRANCH="branch:v2026.01-ascend310b"'
	assert_file_contains "${FAMILY_CONFIG}" 'UBOOT_TARGET_MAP="all;;Image.hboot2 hboot2-uboot.raw"'
	# shellcheck disable=SC2016 # Verify this literal shell expression is present.
	assert_file_contains "${OPIAI_EXTENSION}" '"${base_url}/Image.raw"'
}

test_board_models_only_differ_in_identity_and_dtb() {
	local config_20t config_8t
	config_20t="$(grep '^declare -g ' "${BOARD_CONFIG}" | grep -Ev 'BOARD_NAME=|BOOT_FDT_FILE=' | sort)"
	config_8t="$(grep '^declare -g ' "${BOARD_8T_CONFIG}" | grep -Ev 'BOARD_NAME=|BOOT_FDT_FILE=' | sort)"
	assert_eq "${config_20t}" "${config_8t}" "shared 20T/8T board configuration"

	export BOOT_FDT_FILE="hi1910b/hi1910B-orangepiaipro20t.dtb"
	assert_eq "hi1910B-orangepiaipro20t.dtb" "$(opiai__dtb_name)" "20T DTB selection"
	export BOOT_FDT_FILE="hi1910b/hi1910B-orangepiaipro8t.dtb"
	assert_eq "hi1910B-orangepiaipro8t.dtb" "$(opiai__dtb_name)" "8T DTB selection"
}

test_old_direct_boot_path_is_gone() {
	[[ ! -e "${REPO_ROOT}/extensions/opiai.sh" ]] || fail "legacy extensions/opiai.sh still exists"
	[[ ! -e "${REPO_ROOT}/tools/test-opiai-extension.sh" ]] || fail "legacy test still exists"
	assert_file_not_contains "${OPIAI_EXTENSION}" 'emmc-head'
	assert_file_not_contains "${OPIAI_EXTENSION}" 'itrustee.img'
	assert_file_not_contains "${OPIAI_EXTENSION}" 'post_build_image'
	assert_file_not_contains "${OPIAI_EXTENSION}" 'create_partition_table'
	assert_file_not_contains "${OPIAI_EXTENSION}" 'format_partitions'
	assert_file_not_contains "${OPIAI_EXTENSION}" 'OPIAI_DT_IMAGE_FILE'
	assert_file_not_contains "${OPIAI_EXTENSION}" 'Image.source'
	assert_file_not_contains "${OPIAI_EXTENSION}" '0x2100'
}

run_tests() {
	local test_name
	local -a tests=(
		test_accepts_standard_arm64_image
		test_rejects_hboot2_wrapped_image
		test_rejects_unknown_kernel_image
		test_latest_release_uses_resolved_cache_directory
		test_hboot2_region_limit
		test_write_uboot_uses_one_mib_offset
		test_new_boot_configuration_is_standard
		test_board_models_only_differ_in_identity_and_dtb
		test_old_direct_boot_path_is_gone
	)

	for test_name in "${tests[@]}"; do
		"${test_name}"
		printf 'PASS: %s\n' "${test_name}"
	done
}

run_tests

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
OPIAI_EXTENSION="${REPO_ROOT}/extensions/opiai.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	local expected="${1}"
	local actual="${2}"
	local context="${3:-}"
	[[ "${actual}" == "${expected}" ]] || fail "${context} expected '${expected}', got '${actual}'"
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

branch2dir() {
	local ref="${1}"
	case "${ref}" in
		branch:*)
			echo "${ref#branch:}"
			;;
		commit:*)
			echo "${ref#commit:}"
			;;
		*)
			echo "${ref}"
			;;
	esac
}

fetch_from_repo() {
	:
}

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
	local tmpdir
	tmpdir="$(mktemp -d)"
	cleanup_paths+=("${tmpdir}")
	echo "${tmpdir}"
}

setup_fake_vendor_environment() {
	local tmpdir="${1}"
	local kernel_release="${2}"
	local src_dir="${tmpdir}/src"
	local sdk_dir="${tmpdir}/sdk"
	local build_dir="${tmpdir}/build"
	local output_dir="${build_dir}/output"
	local workspace_dir="${build_dir}/workspace"
	local assets_dir="${src_dir}/cache/sources/opiai/assets"

	mkdir -p "${assets_dir}" \
		"${sdk_dir}/linux-source/arch/arm64/configs" \
		"${output_dir}/modules/lib/modules/${kernel_release}" \
		"${workspace_dir}/dtb/dtbs"
	: > "${assets_dir}/emmc-head"
	chmod 0755 "${assets_dir}/emmc-head"
	: > "${assets_dir}/itrustee.img"
	: > "${sdk_dir}/linux-source/arch/arm64/configs/ascend310B_defconfig"
	: > "${output_dir}/Image"
	: > "${output_dir}/dt.img"
	: > "${output_dir}/linux-modules-${kernel_release}_1_arm64.deb"
	: > "${output_dir}/linux-image-current-ascend310b_1_arm64.deb"
	: > "${workspace_dir}/dtb/dtbs/hi1910B-orangepiaipro20t.dtb"

	export SRC="${src_dir}"
	export BRANCH="current"
	export LINUXFAMILY="ascend310b"
	export INSTALL_HEADERS="no"
	export OPIAI_VENDOR_SOURCE_DIR_OVERRIDE="${sdk_dir}"
	export OPIAI_VENDOR_BUILD_DIR_OVERRIDE="${build_dir}"
	unset OPIAI_ARTIFACTS_READY OPIAI_KERNEL_RELEASE OPIAI_MODULES_DEB OPIAI_IMAGE_DEB OPIAI_DT_IMAGE_FILE OPIAI_DTB_FILE OPIAI_ITRUSTEE_FILE
}

test_branch_mapping() {
	export BRANCH="current"
	assert_eq "branch:6.18" "$(opiai__branch_to_vendor_ref)" "current branch mapping"
	export BRANCH="legacy"
	assert_eq "branch:5.10.0-official" "$(opiai__branch_to_vendor_ref)" "legacy branch mapping"
	export BRANCH="current"
}

test_patch_vendor_source_tree_removes_legacy_cgroup_bootarg() {
	local tmpdir
	local dts_dir
	local dts_file

	tmpdir="$(new_tmpdir)"
	dts_dir="${tmpdir}/sdk/dtb/dts/hi1910b/hi1910BL"
	dts_file="${dts_dir}/hi1910B-orangepiaipro20t.dts"
	mkdir -p "${dts_dir}"
	cat > "${dts_file}" <<'EOF'
/dts-v1/;
/ {
	chosen {
		bootargs = "console=ttyAMA0,115200 systemd.unified_cgroup_hierarchy=0 rootfstype=ext4";
	};
};
EOF

	export SRC="${tmpdir}/src"
	export OPIAI_VENDOR_SOURCE_DIR_OVERRIDE="${tmpdir}/sdk"

	opiai__patch_vendor_source_tree

	assert_file_not_contains "${dts_file}" "systemd.unified_cgroup_hierarchy=0"
	assert_file_contains "${dts_file}" "console=ttyAMA0,115200"
	assert_file_contains "${dts_file}" "rootfstype=ext4"
}

test_cached_artifacts_accept_suffixed_kernel_release() {
	local tmpdir

	tmpdir="$(new_tmpdir)"
	setup_fake_vendor_environment "${tmpdir}" "6.18.18-opiai"

	opiai__load_vendor_kernel_artifacts

	assert_eq "6.18.18-opiai" "${OPIAI_KERNEL_RELEASE}" "accepted cached kernel release"
	assert_eq "${OPIAI_VENDOR_BUILD_DIR_OVERRIDE}/output/Image" "${OPIAI_IMAGE_FILE}" "accepted cached kernel image path"
}

test_script_contains_partuuid_root_spec() {
	assert_file_contains "${OPIAI_EXTENSION}" 'root_device_spec="PARTUUID=${root_partuuid}"'
}

test_script_does_not_force_localversion() {
	assert_file_not_contains "${OPIAI_EXTENSION}" 'KERNEL_RELEASE_SUFFIX='
	assert_file_not_contains "${OPIAI_EXTENSION}" 'CONFIG_LOCALVERSION='
	assert_file_not_contains "${OPIAI_EXTENSION}" 'CONFIG_LOCALVERSION_AUTO'
}

test_vendor_defconfig_file_helper_returns_path() {
	local tmpdir

	tmpdir="$(new_tmpdir)"
	export SRC="${tmpdir}/src"
	export OPIAI_VENDOR_SOURCE_DIR_OVERRIDE="${tmpdir}/sdk"
	assert_eq "${tmpdir}/sdk/linux-source/arch/arm64/configs/ascend310B_defconfig" "$(opiai__vendor_kernel_defconfig_file)" "vendor defconfig helper path"
}

run_tests() {
	local test_name
	local -a tests=(
		test_branch_mapping
		test_patch_vendor_source_tree_removes_legacy_cgroup_bootarg
		test_cached_artifacts_accept_suffixed_kernel_release
		test_script_contains_partuuid_root_spec
		test_script_does_not_force_localversion
		test_vendor_defconfig_file_helper_returns_path
	)

	for test_name in "${tests[@]}"; do
		"${test_name}"
		printf 'PASS: %s\n' "${test_name}"
	done
}

run_tests

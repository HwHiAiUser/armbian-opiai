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
	local download_dir="${src_dir}/cache/sources/opiai/releases/6.18.21"
	local assets_dir="${src_dir}/cache/sources/opiai/assets"

	mkdir -p "${assets_dir}" "${download_dir}"
	: > "${assets_dir}/emmc-head"
	chmod 0755 "${assets_dir}/emmc-head"
	: > "${assets_dir}/itrustee.img"
	: > "${download_dir}/Image"
	: > "${download_dir}/dt.img"
	: > "${download_dir}/hi1910B-orangepiaipro20t.dtb"
	: > "${download_dir}/linux-modules-${kernel_release}_1_arm64.deb"
	: > "${download_dir}/linux-image-current-ascend310b_1_arm64.deb"

	export SRC="${src_dir}"
	export BRANCH="current"
	export LINUXFAMILY="ascend310b"
	export INSTALL_HEADERS="no"
	export OPIAI_KERNEL_VERSION="6.18.21"
	unset OPIAI_ARTIFACTS_READY OPIAI_KERNEL_RELEASE OPIAI_MODULES_DEB OPIAI_IMAGE_DEB OPIAI_DT_IMAGE_FILE OPIAI_DTB_FILE OPIAI_ITRUSTEE_FILE
}

test_branch_mapping() {
	export BRANCH="current"
	assert_eq "branch:6.18" "$(opiai__branch_to_vendor_ref)" "current branch mapping"
	export BRANCH="legacy"
	assert_eq "branch:5.10.0-official" "$(opiai__branch_to_vendor_ref)" "legacy branch mapping"
	export BRANCH="current"
}

test_release_download_dir_uses_version() {
	local tmpdir
	tmpdir="$(new_tmpdir)"
	export SRC="${tmpdir}/src"
	export OPIAI_KERNEL_VERSION="6.18.21"
	assert_eq "${tmpdir}/src/cache/sources/opiai/releases/6.18.21" "$(opiai__release_download_dir)" "release download dir"
}

test_releases_api_url_default() {
	unset OPIAI_RELEASES_API
	local url
	url="$(opiai__releases_api_url)"
	assert_eq "https://api.github.com/repos/HwHiAiUser/kernel-build-opiai/releases" "${url}" "releases api url"
}

test_cached_artifacts_accept_suffixed_kernel_release() {
	local tmpdir

	tmpdir="$(new_tmpdir)"
	setup_fake_vendor_environment "${tmpdir}" "6.18.18-opiai"

	opiai__load_vendor_kernel_artifacts

	assert_eq "6.18.18-opiai" "${OPIAI_KERNEL_RELEASE}" "accepted cached kernel release"
	assert_eq "${SRC}/cache/sources/opiai/releases/6.18.21/Image" "${OPIAI_IMAGE_FILE}" "accepted cached kernel image path"
}

test_script_contains_partuuid_root_spec() {
	assert_file_contains "${OPIAI_EXTENSION}" 'root_device_spec="PARTUUID=${root_partuuid}"'
}

test_script_does_not_force_localversion() {
	assert_file_not_contains "${OPIAI_EXTENSION}" 'KERNEL_RELEASE_SUFFIX='
	assert_file_not_contains "${OPIAI_EXTENSION}" 'CONFIG_LOCALVERSION='
	assert_file_not_contains "${OPIAI_EXTENSION}" 'CONFIG_LOCALVERSION_AUTO'
}

test_kernel_version_default_is_latest() {
	unset OPIAI_KERNEL_VERSION
	assert_eq "latest" "$(opiai__kernel_version)" "default kernel version is latest"
}

test_local_output_dir_overrides_download_dir() {
	local tmpdir
	tmpdir="$(new_tmpdir)"
	export SRC="${tmpdir}/src"
	export OPIAI_LOCAL_OUTPUT_DIR="${tmpdir}/my-output"
	assert_eq "$(realpath -m "${tmpdir}/my-output")" "$(opiai__release_download_dir)" "local output dir override"
	unset OPIAI_LOCAL_OUTPUT_DIR
}

run_tests() {
	local test_name
	local -a tests=(
		test_branch_mapping
		test_release_download_dir_uses_version
		test_releases_api_url_default
		test_cached_artifacts_accept_suffixed_kernel_release
		test_script_contains_partuuid_root_spec
		test_script_does_not_force_localversion
		test_kernel_version_default_is_latest
		test_local_output_dir_overrides_download_dir
	)

	for test_name in "${tests[@]}"; do
		"${test_name}"
		printf 'PASS: %s\n' "${test_name}"
	done
}

run_tests

#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Orange Pi AI Pro boot support:
#   hboot2 -> U-Boot -> extlinux -> standard arm64 Image/DTB/initrd

function opiai__cache_root() {
	echo "${SRC}/cache/sources/opiai"
}

function opiai__releases_api_url() {
	echo "${OPIAI_RELEASES_API:-https://api.github.com/repos/HwHiAiUser/kernel-build-opiai/releases}"
}

function opiai__releases_download_url() {
	echo "${OPIAI_RELEASES_DOWNLOAD:-https://github.com/HwHiAiUser/kernel-build-opiai/releases/download}"
}

function opiai__kernel_version() {
	echo "${OPIAI_KERNEL_VERSION:-latest}"
}

function opiai__dtb_name() {
	local configured_dtb="${BOOT_FDT_FILE:-}"
	local dtb_name="${configured_dtb##*/}"

	case "${dtb_name}" in
		hi1910B-orangepiaipro20t.dtb | hi1910B-orangepiaipro8t.dtb)
			echo "${dtb_name}"
			;;
		*)
			exit_with_error "Unsupported Orange Pi AI Pro DTB" "${BOOT_FDT_FILE:-unset}"
			return 1
			;;
	esac
}

function opiai__release_download_dir() {
	local version="${1:-${OPIAI_RESOLVED_KERNEL_VERSION:-$(opiai__kernel_version)}}"

	if [[ -n "${OPIAI_LOCAL_OUTPUT_DIR:-}" ]]; then
		realpath -m "${OPIAI_LOCAL_OUTPUT_DIR}"
		return 0
	fi

	echo "$(opiai__cache_root)/releases/${version}"
}

function opiai__resolve_release_tag() {
	local version
	version="$(opiai__kernel_version)"

	if [[ "${version}" == "latest" ]]; then
		local api_url
		api_url="$(opiai__releases_api_url)/latest"
		display_alert "Resolving latest Orange Pi AI Pro kernel release" "${api_url}" "info"
		version="$(curl -fsSL "${api_url}" | jq -r '.tag_name')"
		if [[ -z "${version}" || "${version}" == "null" ]]; then
			exit_with_error "Unable to resolve latest Orange Pi AI Pro kernel release" "${api_url}"
			return 1
		fi
	fi

	echo "${version}"
}

function opiai__require_file() {
	local file_path="${1}"
	if [[ ! -f "${file_path}" ]]; then
		exit_with_error "Missing required Orange Pi AI Pro input" "${file_path}"
		return 1
	fi
}

function opiai__download_artifact() {
	local url="${1}"
	local destination="${2}"

	if [[ -f "${destination}" ]]; then
		display_alert "Using cached Orange Pi AI Pro artifact" "$(basename "${destination}")" "info"
		return 0
	fi

	run_host_command_logged mkdir -p "$(dirname "${destination}")"
	display_alert "Downloading Orange Pi AI Pro artifact" "$(basename "${destination}")" "info"
	run_host_command_logged curl -fSL --retry 3 --retry-delay 5 -o "${destination}.tmp" "${url}"
	run_host_command_logged mv "${destination}.tmp" "${destination}"
}

function opiai__find_release_deb() {
	local tag="${1}"
	local prefix="${2}"
	local download_dir="${3}"
	local cached_deb api_url asset_name asset_url

	cached_deb="$(find "${download_dir}" -maxdepth 1 -type f -name "${prefix}*.deb" 2>/dev/null | sort | head -n 1)"
	if [[ -n "${cached_deb}" ]]; then
		echo "${cached_deb}"
		return 0
	fi

	[[ "${tag}" != "local" ]] || return 1
	api_url="$(opiai__releases_api_url)/tags/${tag}"
	asset_name="$(curl -fsSL "${api_url}" | jq -r --arg prefix "${prefix}" '.assets[] | select(.name | startswith($prefix)) | select(.name | endswith(".deb")) | .name' | sort | head -n 1)"
	[[ -n "${asset_name}" && "${asset_name}" != "null" ]] || return 1

	asset_url="$(opiai__releases_download_url)/${tag}/${asset_name}"
	opiai__download_artifact "${asset_url}" "${download_dir}/${asset_name}"
	echo "${download_dir}/${asset_name}"
}

function opiai__arm64_image_magic() {
	local image_file="${1}"

	od -An -tx1 -N4 -j $((0x38)) "${image_file}" 2>/dev/null | tr -d ' \n'
}

function opiai__is_standard_arm64_linux_image() {
	local image_file="${1}"

	[[ -f "${image_file}" ]] && [[ "$(opiai__arm64_image_magic "${image_file}")" == "41524d64" ]]
}

function opiai__validate_standard_linux_image() {
	local image_file="${1}"

	opiai__require_file "${image_file}" || return 1
	if ! opiai__is_standard_arm64_linux_image "${image_file}"; then
		exit_with_error "Unsupported Orange Pi AI Pro kernel Image format" "ARM64 magic not found at 0x38 in ${image_file}"
		return 1
	fi
	display_alert "Using standard arm64 Linux Image" "${image_file}" "info"
}

function opiai__stage_local_kernel_artifacts() {
	local source_dir="${1}"
	local stage_dir="${2}"
	local dtb_name dtb_source=""
	local candidate artifact

	dtb_name="$(opiai__dtb_name)" || return 1
	opiai__require_file "${source_dir}/Image.raw" || return 1
	run_host_command_logged rm -rf "${stage_dir}"
	run_host_command_logged mkdir -p "${stage_dir}"
	run_host_command_logged cp -f "${source_dir}/Image.raw" "${stage_dir}/Image.raw"

	for candidate in \
		"${source_dir}/${dtb_name}" \
		"${source_dir}/../workspace/dtb/dtbs/${dtb_name}"; do
		if [[ -f "${candidate}" ]]; then
			dtb_source="$(realpath "${candidate}")"
			break
		fi
	done
	if [[ -z "${dtb_source}" ]]; then
		exit_with_error "Cannot find Orange Pi AI Pro DTB in local kernel output" "${source_dir}"
		return 1
	fi
	run_host_command_logged cp -f "${dtb_source}" "${stage_dir}/${dtb_name}"

	for artifact in "${source_dir}"/linux-modules-*.deb "${source_dir}"/linux-headers-*.deb; do
		[[ -f "${artifact}" ]] && run_host_command_logged cp -f "${artifact}" "${stage_dir}/$(basename "${artifact}")"
	done

	if ! find "${stage_dir}" -maxdepth 1 -type f -name 'linux-modules-*.deb' | grep -q .; then
		exit_with_error "Missing modules package in local Orange Pi AI Pro kernel output" "${source_dir}"
		return 1
	fi
}

function host_pre_docker_launch__500_opiai_stage_local_kernel() {
	[[ -n "${OPIAI_LOCAL_OUTPUT_DIR:-}" ]] || return 0

	local source_dir stage_dir
	source_dir="$(realpath -m "${OPIAI_LOCAL_OUTPUT_DIR}")"
	stage_dir="$(opiai__cache_root)/releases/local"
	display_alert "Staging local Orange Pi AI Pro kernel for container build" "${source_dir}" "info"
	opiai__stage_local_kernel_artifacts "${source_dir}" "${stage_dir}"

	declare -g OPIAI_KERNEL_VERSION="local"
	unset OPIAI_LOCAL_OUTPUT_DIR
}

function opiai__prepare_release_artifacts() {
	local tag download_dir base_url dtb_name kernel_image modules_deb headers_deb candidate

	dtb_name="$(opiai__dtb_name)" || return 1

	if [[ -n "${OPIAI_LOCAL_OUTPUT_DIR:-}" ]]; then
		tag="local"
		download_dir="$(opiai__release_download_dir local)"
		opiai__require_file "${download_dir}/Image.raw" || return 1
		if [[ ! -f "${download_dir}/${dtb_name}" ]]; then
			for candidate in \
				"${download_dir}/../workspace/dtb/dtbs/${dtb_name}" \
				"$(dirname "${download_dir}")/workspace/dtb/dtbs/${dtb_name}"; do
				if [[ -f "${candidate}" ]]; then
					run_host_command_logged cp -f "${candidate}" "${download_dir}/${dtb_name}"
					break
				fi
			done
		fi
	else
		tag="$(opiai__resolve_release_tag)"
		declare -g OPIAI_RESOLVED_KERNEL_VERSION="${tag}"
		download_dir="$(opiai__release_download_dir "${tag}")"
		base_url="$(opiai__releases_download_url)/${tag}"
		run_host_command_logged mkdir -p "${download_dir}"
		opiai__download_artifact "${base_url}/Image.raw" "${download_dir}/Image.raw"
		opiai__download_artifact "${base_url}/${dtb_name}" "${download_dir}/${dtb_name}"
	fi

	kernel_image="${download_dir}/Image.raw"
	opiai__validate_standard_linux_image "${kernel_image}" || return 1
	opiai__require_file "${download_dir}/${dtb_name}" || return 1
	modules_deb="$(opiai__find_release_deb "${tag}" "linux-modules-" "${download_dir}")"
	if [[ -z "${modules_deb}" || ! -f "${modules_deb}" ]]; then
		exit_with_error "Unable to find Orange Pi AI Pro modules package" "${tag}"
		return 1
	fi

	headers_deb=""
	if [[ "${INSTALL_HEADERS:-no}" == "yes" ]]; then
		headers_deb="$(opiai__find_release_deb "${tag}" "linux-headers-" "${download_dir}")"
		if [[ -z "${headers_deb}" || ! -f "${headers_deb}" ]]; then
			exit_with_error "Unable to find Orange Pi AI Pro headers package" "${tag}"
			return 1
		fi
	fi

	declare -g OPIAI_VENDOR_OUTPUT_DIR="${download_dir}"
	declare -g OPIAI_MODULES_DEB="${modules_deb}"
	declare -g OPIAI_HEADERS_DEB="${headers_deb}"
	declare -g OPIAI_DTB_NAME="${dtb_name}"
	declare -g OPIAI_DTB_FILE="${download_dir}/${dtb_name}"
	declare -g OPIAI_IMAGE_FILE="${kernel_image}"
}

function opiai__build_kernel_image_deb() {
	local download_dir="${1}"
	local kernel_release="${2}"
	local modules_package="${3}"
	local modules_version="${4}"
	local safe_version package_name package_root debian_dir image_deb image_dir

	safe_version="${modules_version//:/_}"
	safe_version="${safe_version//\//_}"
	package_name="linux-image-opiai-${BRANCH}-${LINUXFAMILY}"
	package_root="${download_dir}/image-deb/pkgroot"
	debian_dir="${package_root}/DEBIAN"
	image_dir="/usr/lib/linux-image-${kernel_release}"
	image_deb="${download_dir}/${package_name}_${safe_version}_arm64.deb"

	run_host_command_logged rm -rf "${download_dir}/image-deb"
	run_host_command_logged mkdir -p \
		"${debian_dir}" \
		"${package_root}/boot/dtb/hi1910b" \
		"${package_root}${image_dir}/hi1910b"
	run_host_command_logged install -m 0644 "${OPIAI_IMAGE_FILE}" "${package_root}/boot/vmlinuz-${kernel_release}"
	run_host_command_logged ln -s "vmlinuz-${kernel_release}" "${package_root}/boot/Image-${kernel_release}"
	run_host_command_logged install -m 0644 "${OPIAI_DTB_FILE}" "${package_root}/boot/dtb/hi1910b/${OPIAI_DTB_NAME}"
	run_host_command_logged install -m 0644 "${OPIAI_DTB_FILE}" "${package_root}${image_dir}/hi1910b/${OPIAI_DTB_NAME}"

	cat > "${debian_dir}/control" <<- EOF
		Package: ${package_name}
		Version: ${modules_version}
		Section: kernel
		Priority: optional
		Architecture: arm64
		Source: linux-${kernel_release}
		Depends: ${modules_package} (= ${modules_version})
		Maintainer: Orange Pi AI Pro Armbian Builder <noreply@local>
		Description: Standard U-Boot boot files for Orange Pi AI Pro (${kernel_release})
	EOF

	cat > "${debian_dir}/postinst" <<- EOF
		#!/bin/sh
		set -e
		ln -sf "vmlinuz-${kernel_release}" /boot/Image
		ln -sf "vmlinuz-${kernel_release}" /boot/vmlinuz
		exit 0
	EOF
	run_host_command_logged chmod 0755 "${debian_dir}/postinst"
	run_host_command_logged fakeroot dpkg-deb --build "${package_root}" "${image_deb}"

	declare -g OPIAI_IMAGE_DEB="${image_deb}"
}

function opiai__prepare_kernel_artifacts() {
	[[ "${OPIAI_ARTIFACTS_READY:-no}" == "yes" ]] && return 0

	local modules_package modules_version kernel_release
	opiai__prepare_release_artifacts

	modules_package="$(dpkg-deb -f "${OPIAI_MODULES_DEB}" Package)"
	modules_version="$(dpkg-deb -f "${OPIAI_MODULES_DEB}" Version)"
	kernel_release="${modules_package#linux-modules-}"
	if [[ -z "${modules_package}" || -z "${modules_version}" || -z "${kernel_release}" || "${kernel_release}" == "${modules_package}" ]]; then
		exit_with_error "Unable to read Orange Pi AI Pro modules package metadata" "${OPIAI_MODULES_DEB}"
		return 1
	fi

	opiai__build_kernel_image_deb "${OPIAI_VENDOR_OUTPUT_DIR}" "${kernel_release}" "${modules_package}" "${modules_version}"
	declare -g OPIAI_KERNEL_RELEASE="${kernel_release}"
	declare -g OPIAI_ARTIFACTS_READY="yes"
}

function pre_install_kernel_debs__500_opiai_install_external_kernel() {
	opiai__prepare_kernel_artifacts
	install_deb_chroot "${OPIAI_MODULES_DEB}" "" "" ""
	install_deb_chroot "${OPIAI_IMAGE_DEB}" "" "" ""
	if [[ "${INSTALL_HEADERS:-no}" == "yes" ]]; then
		install_deb_chroot "${OPIAI_HEADERS_DEB}" "" "" ""
	fi
}

function post_install_kernel_debs__500_opiai_enable_standard_initramfs() {
	opiai__prepare_kernel_artifacts
	declare -g IMAGE_INSTALLED_KERNEL_VERSION="${OPIAI_KERNEL_RELEASE}"
	# The external packages are now installed. A non-'none' marker lets the
	# standard rootfs-to-image stage create initrd.img and uInitrd once.
	# shellcheck disable=SC2034 # Consumed by the Armbian framework after this hook returns.
	declare -g KERNELSOURCE="external-opiai"
	display_alert "Installed external Orange Pi AI Pro kernel" "${IMAGE_INSTALLED_KERNEL_VERSION}" "info"
}

function fetch_sources_tools__700_opiai_hboot2_image_generator() {
	fetch_from_repo \
		"https://github.com/HwHiAiUser/scripts" \
		"opiai-hboot2-tools" \
		"commit:687d94e050fd59c58ea0b4814929fc7cf05f5282"
}

function opiai__hboot2_region_max_bytes() {
	local rootfs_offset_mib="${1:-${OFFSET:-32}}"
	if ((rootfs_offset_mib <= 1)); then
		exit_with_error "Invalid Orange Pi AI Pro rootfs offset" "${rootfs_offset_mib} MiB"
		return 1
	fi
	echo $(((rootfs_offset_mib - 1) * 1024 * 1024))
}

function opiai__validate_hboot2_region_size() {
	local raw_image="${1}"
	local rootfs_offset_mib="${2:-${OFFSET:-32}}"
	local image_size maximum_size

	opiai__require_file "${raw_image}" || return 1
	image_size="$(stat -c '%s' "${raw_image}")"
	maximum_size="$(opiai__hboot2_region_max_bytes "${rootfs_offset_mib}")"
	if ((image_size > maximum_size)); then
		exit_with_error "Orange Pi AI Pro hboot2 U-Boot region overlaps rootfs" "${image_size} bytes > ${maximum_size} bytes"
		return 1
	fi
}

function post_uboot_custom_postprocess__700_opiai_build_hboot2_region() {
	local uboot_dir tools_dir layout_dir expected_tools_commit actual_tools_commit
	uboot_dir="$(pwd)"
	tools_dir="${SRC}/cache/sources/opiai-hboot2-tools"
	layout_dir="${WORKDIR}/opiai-hboot2-layout-${uboot_target_counter:-0}"
	expected_tools_commit="687d94e050fd59c58ea0b4814929fc7cf05f5282"

	opiai__require_file "${uboot_dir}/Image.hboot2" || return 1
	opiai__require_file "${tools_dir}/hboot2imgen.py" || return 1
	opiai__require_file "${tools_dir}/hboot2imgen.uboot.json" || return 1
	opiai__require_file "${tools_dir}/resources/dt.img" || return 1
	opiai__require_file "${tools_dir}/resources/tee.img" || return 1
	actual_tools_commit="$(git -C "${tools_dir}" rev-parse HEAD)"
	if [[ "${actual_tools_commit}" != "${expected_tools_commit}" ]]; then
		exit_with_error "Unexpected hboot2 image generator revision" "${actual_tools_commit}"
		return 1
	fi

	run_host_command_logged rm -rf "${layout_dir}"
	run_host_command_logged mkdir -p "${layout_dir}/scripts/resources" "${layout_dir}/u-boot"
	run_host_command_logged install -m 0755 "${tools_dir}/hboot2imgen.py" "${layout_dir}/scripts/hboot2imgen.py"
	run_host_command_logged install -m 0644 "${tools_dir}/hboot2imgen.uboot.json" "${layout_dir}/scripts/hboot2imgen.uboot.json"
	run_host_command_logged install -m 0644 "${tools_dir}/resources/dt.img" "${layout_dir}/scripts/resources/dt.img"
	run_host_command_logged install -m 0644 "${tools_dir}/resources/tee.img" "${layout_dir}/scripts/resources/tee.img"
	run_host_command_logged install -m 0644 "${uboot_dir}/Image.hboot2" "${layout_dir}/u-boot/Image.hboot2"

	(
		cd "${layout_dir}/scripts" || exit 1
		run_host_command_logged python3 ./hboot2imgen.py ./hboot2imgen.uboot.json "${uboot_dir}/hboot2-uboot.raw"
	)
	opiai__validate_hboot2_region_size "${uboot_dir}/hboot2-uboot.raw" "${OFFSET:-32}"
	run_host_command_logged rm -rf "${layout_dir}"
}

function write_uboot_platform() {
	local source_dir="${1}"
	local target_device="${2}"
	local raw_image="${source_dir}/hboot2-uboot.raw"
	local rootfs_offset_mib=32
	local maximum_size=$(((rootfs_offset_mib - 1) * 1024 * 1024))
	local image_size logging_prelude=""

	if [[ ! -f "${raw_image}" ]]; then
		echo "Missing Orange Pi AI Pro hboot2 U-Boot image: ${raw_image}" >&2
		return 1
	fi
	image_size="$(stat -c '%s' "${raw_image}")"
	if ((image_size > maximum_size)); then
		echo "Orange Pi AI Pro hboot2 U-Boot image overlaps the rootfs: ${image_size} > ${maximum_size}" >&2
		return 1
	fi

	[[ "$(type -t run_host_command_logged)" == "function" ]] && logging_prelude="run_host_command_logged"
	${logging_prelude} dd "if=${raw_image}" "of=${target_device}" bs=1M seek=1 conv=fsync,notrunc status=none
}

function add_host_dependencies__opiai_uboot_host_dependencies() {
	declare -g EXTRA_BUILD_DEPS="${EXTRA_BUILD_DEPS} fakeroot curl jq"
}

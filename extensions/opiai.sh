function add_host_dependencies__opiai_host_deps() {
	declare -g EXTRA_BUILD_DEPS="${EXTRA_BUILD_DEPS} fakeroot dosfstools device-tree-compiler kmod qemu-user-static wget curl jq"
}

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

function opiai__assets_dir() {
	echo "${OPIAI_ASSETS_DIR_OVERRIDE:-$(opiai__cache_root)/assets}"
}

function opiai__firmware_download_url() {
	echo "${OPIAI_FIRMWARE_DOWNLOAD_URL:-https://github.com/HwHiAiUser/kernel-build-opiai/releases/download/assets}"
}

function opiai__emmc_head_binary() {
	echo "$(opiai__assets_dir)/emmc-head"
}

function opiai__itrustee_image() {
	echo "$(opiai__assets_dir)/itrustee.img"
}

function opiai__raw_boot_image_sector() {
	echo 32768
}

function opiai__raw_boot_image_b_sector() {
	echo 294912
}

function opiai__raw_boot_dtb_sector() {
	echo 114688
}

function opiai__raw_boot_dtb_b_sector() {
	echo 376832
}

function opiai__raw_boot_tee_sector() {
	echo 122880
}

function opiai__raw_boot_tee_b_sector() {
	echo 385024
}

function opiai__partition_head_sector() {
	echo 2048
}

function opiai__partition_head_backup_sector() {
	echo 2176
}

function opiai__boot_image_info_sector() {
	echo 2304
}

function opiai__branch_to_vendor_ref() {
	case "${BRANCH}" in
		current)
			echo "branch:6.18"
			;;
		legacy)
			echo "branch:5.10.0-official"
			;;
		*)
			exit_with_error "Unsupported Armbian branch for ${BOARD}" "${BRANCH}; expected current or legacy"
			;;
	esac
}

function opiai__require_file() {
	local file_path="${1}"
	[[ -f "${file_path}" ]] || exit_with_error "Missing required Orange Pi AI Pro 20T input" "${file_path}"
}

function opiai__require_executable() {
	local file_path="${1}"
	[[ -x "${file_path}" ]] || exit_with_error "Missing required executable Orange Pi AI Pro 20T input" "${file_path}"
}

function opiai__require_directory() {
	local dir_path="${1}"
	[[ -d "${dir_path}" ]] || exit_with_error "Missing required Orange Pi AI Pro 20T input" "${dir_path}"
}

function opiai__stage_vendor_assets() {
	local assets_dir
	local emmc_dst
	local itrustee_dst
	local base_url

	assets_dir="$(opiai__assets_dir)"
	emmc_dst="$(opiai__emmc_head_binary)"
	itrustee_dst="$(opiai__itrustee_image)"

	if [[ -f "${emmc_dst}" && -f "${itrustee_dst}" ]]; then
		return 0
	fi

	base_url="$(opiai__firmware_download_url)"
	run_host_command_logged mkdir -p "${assets_dir}"

	opiai__download_artifact "${base_url}/emmc-head" "${emmc_dst}"
	run_host_command_logged chmod 0755 "${emmc_dst}"
	opiai__download_artifact "${base_url}/itrustee.img" "${itrustee_dst}"
}

function host_pre_docker_launch__500_opiai_stage_assets() {
	opiai__stage_vendor_assets

	# When OPIAI_LOCAL_OUTPUT_DIR is set, stage local artifacts into the
	# cache directory that gets bind-mounted into the Docker container.
	# Use cp (not symlinks) because container bind-mounts cannot follow
	# host-absolute symlinks whose targets are outside the mount tree.
	if [[ -n "${OPIAI_LOCAL_OUTPUT_DIR:-}" ]]; then
		local src_dir
		local stage_dir
		src_dir="$(realpath -m "${OPIAI_LOCAL_OUTPUT_DIR}")"
		stage_dir="$(opiai__cache_root)/releases/local"

		display_alert "Staging local kernel artifacts for Docker" "${src_dir} -> ${stage_dir}" "info"
		run_host_command_logged rm -rf "${stage_dir}"
		run_host_command_logged mkdir -p "${stage_dir}"

		local f
		for f in Image dt.img; do
			[[ -f "${src_dir}/${f}" ]] || exit_with_error "Missing local artifact" "${src_dir}/${f}"
			run_host_command_logged cp -f "${src_dir}/${f}" "${stage_dir}/${f}"
		done

		# DTB might be in a sibling workspace directory
		if [[ ! -f "${stage_dir}/hi1910B-orangepiaipro20t.dtb" ]]; then
			local dtb_found=""
			local dtb_candidate
			for dtb_candidate in \
				"${src_dir}/hi1910B-orangepiaipro20t.dtb" \
				"${src_dir}/../workspace/dtb/dtbs/hi1910B-orangepiaipro20t.dtb"; do
				if [[ -f "${dtb_candidate}" ]]; then
					dtb_found="$(realpath "${dtb_candidate}")"
					break
				fi
			done
			[[ -n "${dtb_found}" ]] || exit_with_error "Cannot find DTB in local build tree" "${src_dir}"
			run_host_command_logged cp -f "${dtb_found}" "${stage_dir}/hi1910B-orangepiaipro20t.dtb"
		fi

		# Copy deb packages
		for f in "${src_dir}"/linux-modules-*.deb "${src_dir}"/linux-headers-*.deb; do
			[[ -f "${f}" ]] && run_host_command_logged cp -f "${f}" "${stage_dir}/$(basename "${f}")"
		done

		# Tell the in-container build to use the staged dir
		declare -g OPIAI_KERNEL_VERSION="local"
		unset OPIAI_LOCAL_OUTPUT_DIR
	fi
}

function opiai__release_download_dir() {
	if [[ -n "${OPIAI_LOCAL_OUTPUT_DIR:-}" ]]; then
		echo "$(realpath -m "${OPIAI_LOCAL_OUTPUT_DIR}")"
		return 0
	fi
	echo "$(opiai__cache_root)/releases/$(opiai__kernel_version)"
}

function opiai__resolve_release_tag() {
	local version
	version="$(opiai__kernel_version)"

	if [[ "${version}" == "latest" ]]; then
		local api_url
		api_url="$(opiai__releases_api_url)/latest"
		display_alert "Resolving latest Orange Pi AI Pro 20T kernel release" "${api_url}" "info"
		version="$(curl -fsSL "${api_url}" | jq -r '.tag_name')"
		[[ -n "${version}" && "${version}" != "null" ]] || exit_with_error "Unable to resolve latest kernel release tag" "${api_url}"
		display_alert "Resolved Orange Pi AI Pro 20T kernel release" "${version}" "info"
	fi

	echo "${version}"
}

function opiai__download_artifact() {
	local url="${1}"
	local dest="${2}"

	if [[ -f "${dest}" ]]; then
		display_alert "Cached" "$(basename "${dest}")" "info"
		return 0
	fi

	display_alert "Downloading" "$(basename "${dest}")" "info"
	run_host_command_logged curl -fSL --retry 3 --retry-delay 5 -o "${dest}.tmp" "${url}"
	run_host_command_logged mv "${dest}.tmp" "${dest}"
}

function opiai__download_release_artifacts() {
	local tag
	local download_dir
	local base_url

	download_dir="$(opiai__release_download_dir)"

	if [[ -n "${OPIAI_LOCAL_OUTPUT_DIR:-}" ]]; then
		display_alert "Using local kernel artifacts" "${download_dir}" "info"
		opiai__require_file "${download_dir}/Image"
		opiai__require_file "${download_dir}/dt.img"

		# In the local build tree the DTB lives under ../workspace/dtb/dtbs/
		if [[ ! -f "${download_dir}/hi1910B-orangepiaipro20t.dtb" ]]; then
			local local_base
			local_base="$(dirname "${download_dir}")"
			local dtb_candidates=(
				"${local_base}/workspace/dtb/dtbs/hi1910B-orangepiaipro20t.dtb"
				"${download_dir}/../workspace/dtb/dtbs/hi1910B-orangepiaipro20t.dtb"
			)
			local found_dtb=""
			for c in "${dtb_candidates[@]}"; do
				if [[ -f "${c}" ]]; then
					found_dtb="$(realpath "${c}")"
					break
				fi
			done
			[[ -n "${found_dtb}" ]] || exit_with_error "Cannot find DTB for local build" "${download_dir}"
			run_host_command_logged cp -f "${found_dtb}" "${download_dir}/hi1910B-orangepiaipro20t.dtb"
		fi
		return 0
	fi

	tag="$(opiai__resolve_release_tag)"
	base_url="$(opiai__releases_download_url)/${tag}"

	run_host_command_logged mkdir -p "${download_dir}"

	opiai__download_artifact "${base_url}/Image" "${download_dir}/Image"
	opiai__download_artifact "${base_url}/dt.img" "${download_dir}/dt.img"
	opiai__download_artifact "${base_url}/hi1910B-orangepiaipro20t.dtb" "${download_dir}/hi1910B-orangepiaipro20t.dtb"

	local modules_deb
	modules_deb="$(opiai__find_release_deb "${tag}" "linux-modules-" "${download_dir}")"
	[[ -n "${modules_deb}" ]] || exit_with_error "Unable to find modules deb in release" "${tag}"

	if [[ "${INSTALL_HEADERS:-no}" == "yes" ]]; then
		local headers_deb
		headers_deb="$(opiai__find_release_deb "${tag}" "linux-headers-" "${download_dir}")"
		[[ -n "${headers_deb}" ]] || exit_with_error "Unable to find headers deb in release" "${tag}"
	fi
}

function opiai__find_release_deb() {
	local tag="${1}"
	local prefix="${2}"
	local download_dir="${3}"
	local cached_deb
	local api_url
	local asset_name
	local asset_url

	cached_deb="$(find "${download_dir}" -maxdepth 1 -type f -name "${prefix}*.deb" 2>/dev/null | sort | head -n 1)"
	if [[ -n "${cached_deb}" ]]; then
		echo "${cached_deb}"
		return 0
	fi

	api_url="$(opiai__releases_api_url)/tags/${tag}"
	asset_name="$(curl -fsSL "${api_url}" | jq -r --arg prefix "${prefix}" '.assets[] | select(.name | startswith($prefix)) | select(.name | endswith(".deb")) | .name' | sort | head -n 1)"
	[[ -n "${asset_name}" && "${asset_name}" != "null" ]] || return 1

	asset_url="$(opiai__releases_download_url)/${tag}/${asset_name}"
	opiai__download_artifact "${asset_url}" "${download_dir}/${asset_name}"
	echo "${download_dir}/${asset_name}"
}

function opiai__find_qemu_binary() {
	if command -v qemu-aarch64 >/dev/null 2>&1; then
		command -v qemu-aarch64
		return 0
	fi

	if command -v qemu-aarch64-static >/dev/null 2>&1; then
		command -v qemu-aarch64-static
		return 0
	fi

	exit_with_error "Missing qemu user emulator" "qemu-aarch64 or qemu-aarch64-static"
}

function opiai__find_aarch64_libdir() {
	local candidate=""
	for candidate in /usr/aarch64-linux-gnu/lib /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu; do
		if [[ -d "${candidate}" ]]; then
			echo "${candidate}"
			return 0
		fi
	done

	exit_with_error "Missing AArch64 userspace libraries for emmc-head" "looked under /usr/aarch64-linux-gnu/lib and /usr/lib/aarch64-linux-gnu"
}

function opiai__create_qemu_sysroot() {
	local sysroot_dir="${1}"
	local libdir="${2}"

	run_host_command_logged mkdir -p "${sysroot_dir}" "${sysroot_dir}/usr"
	run_host_command_logged ln -snf "${libdir}" "${sysroot_dir}/lib"
	run_host_command_logged ln -snf "${libdir}" "${sysroot_dir}/lib64"
	run_host_command_logged ln -snf "${libdir}" "${sysroot_dir}/usr/lib"
}

function opiai__load_vendor_kernel_artifacts() {
	local download_dir
	local kernel_release
	local modules_deb
	local headers_deb=""
	local dtb_file
	local image_deb

	opiai__stage_vendor_assets
	download_dir="$(opiai__release_download_dir)"

	[[ -d "${download_dir}" ]] || return 1
	[[ -f "${download_dir}/Image" ]] || return 1
	[[ -f "${download_dir}/dt.img" ]] || return 1

	dtb_file="${download_dir}/hi1910B-orangepiaipro20t.dtb"
	[[ -f "${dtb_file}" ]] || return 1

	modules_deb="$(find "${download_dir}" -maxdepth 1 -type f -name "linux-modules-*.deb" | sort | head -n 1)"
	[[ -n "${modules_deb}" && -f "${modules_deb}" ]] || return 1

	kernel_release="$(basename "${modules_deb}" | sed -E 's/^linux-modules-([^_]+)_.*/\1/')"
	[[ -n "${kernel_release}" ]] || return 1

	if [[ "${INSTALL_HEADERS:-no}" == "yes" ]]; then
		headers_deb="$(find "${download_dir}" -maxdepth 1 -type f -name "linux-headers-*.deb" | sort | head -n 1)"
		[[ -n "${headers_deb}" && -f "${headers_deb}" ]] || return 1
	fi

	image_deb="$(find "${download_dir}" -maxdepth 1 -type f -name "linux-image-*.deb" | sort | head -n 1)"
	[[ -n "${image_deb}" && -f "${image_deb}" ]] || return 1
	[[ -f "$(opiai__itrustee_image)" ]] || return 1

	declare -g OPIAI_VENDOR_OUTPUT_DIR="${download_dir}"
	declare -g OPIAI_KERNEL_RELEASE="${kernel_release}"
	declare -g OPIAI_MODULES_DEB="${modules_deb}"
	declare -g OPIAI_HEADERS_DEB="${headers_deb}"
	declare -g OPIAI_IMAGE_DEB="${image_deb}"
	declare -g OPIAI_IMAGE_FILE="${download_dir}/Image"
	declare -g OPIAI_DT_IMAGE_FILE="${download_dir}/dt.img"
	declare -g OPIAI_DTB_FILE="${dtb_file}"
	declare -g OPIAI_ITRUSTEE_FILE="$(opiai__itrustee_image)"
	declare -g OPIAI_ARTIFACTS_READY="yes"
	return 0
}

function opiai__build_vendor_kernel_artifacts() {
	if opiai__load_vendor_kernel_artifacts; then
		display_alert "Reusing cached Orange Pi AI Pro 20T kernel artifacts" "$(opiai__release_download_dir)" "info"
		return 0
	fi

	if [[ "${OPIAI_ARTIFACTS_READY:-no}" == "yes" ]]; then
		exit_with_error "Orange Pi AI Pro 20T kernel artifacts cache is incomplete" "$(opiai__release_download_dir)"
	fi

	opiai__stage_vendor_assets
	opiai__download_release_artifacts

	local download_dir
	local kernel_release
	local modules_deb
	local headers_deb=""
	local dtb_file
	local package_version

	download_dir="$(opiai__release_download_dir)"

	modules_deb="$(find "${download_dir}" -maxdepth 1 -type f -name "linux-modules-*.deb" | sort | head -n 1)"
	[[ -n "${modules_deb}" ]] || exit_with_error "Unable to locate downloaded modules deb" "${download_dir}"

	kernel_release="$(basename "${modules_deb}" | sed -E 's/^linux-modules-([^_]+)_.*/\1/')"
	[[ -n "${kernel_release}" ]] || exit_with_error "Unable to determine kernel release from modules deb" "${modules_deb}"

	if [[ "${INSTALL_HEADERS:-no}" == "yes" ]]; then
		headers_deb="$(find "${download_dir}" -maxdepth 1 -type f -name "linux-headers-*.deb" | sort | head -n 1)"
		[[ -n "${headers_deb}" ]] || exit_with_error "Unable to locate downloaded headers deb" "${download_dir}"
	fi

	dtb_file="${download_dir}/hi1910B-orangepiaipro20t.dtb"
	opiai__require_file "${dtb_file}"
	opiai__require_file "${download_dir}/Image"
	opiai__require_file "${download_dir}/dt.img"

	if [[ -n "${OPIAI_LOCAL_OUTPUT_DIR:-}" ]]; then
		# Derive version from modules deb filename instead of querying GitHub API
		package_version="$(basename "${modules_deb}" | sed -E 's/^linux-modules-[^_]+_([^_]+)_.*/\1/')"
	else
		package_version="$(opiai__resolve_release_tag)"
	fi
	local image_deb="${download_dir}/linux-image-${BRANCH}-${LINUXFAMILY}_${package_version}_arm64.deb"

	opiai__build_vendor_image_deb "${download_dir}" "${kernel_release}" "${dtb_file}" "${image_deb}" "${package_version}"

	declare -g OPIAI_VENDOR_OUTPUT_DIR="${download_dir}"
	declare -g OPIAI_KERNEL_RELEASE="${kernel_release}"
	declare -g OPIAI_MODULES_DEB="${modules_deb}"
	declare -g OPIAI_HEADERS_DEB="${headers_deb}"
	declare -g OPIAI_IMAGE_DEB="${image_deb}"
	declare -g OPIAI_IMAGE_FILE="${download_dir}/Image"
	declare -g OPIAI_DT_IMAGE_FILE="${download_dir}/dt.img"
	declare -g OPIAI_DTB_FILE="${dtb_file}"
	declare -g OPIAI_ITRUSTEE_FILE="$(opiai__itrustee_image)"
	declare -g OPIAI_ARTIFACTS_READY="yes"
}

function opiai__build_vendor_image_deb() {
	local download_dir="${1}"
	local kernel_release="${2}"
	local dtb_file="${3}"
	local image_deb="${4}"
	local package_version="${5}"
	local package_name="linux-image-${BRANCH}-${LINUXFAMILY}"
	local package_root="${download_dir}/image-deb/pkgroot"
	local image_dir="/usr/lib/linux-image-${kernel_release}"
	local debian_dir="${package_root}/DEBIAN"

	run_host_command_logged rm -rf "${download_dir}/image-deb"
	run_host_command_logged mkdir -p "${debian_dir}" \
		"${package_root}/boot/dtb/hi1910b" \
		"${package_root}${image_dir}/hi1910b"

	run_host_command_logged install -m 0644 "${download_dir}/Image" "${package_root}/boot/Image-${kernel_release}"
	run_host_command_logged install -m 0644 "${dtb_file}" "${package_root}/boot/dtb/hi1910b/hi1910B-orangepiaipro20t.dtb"
	run_host_command_logged install -m 0644 "${dtb_file}" "${package_root}${image_dir}/hi1910b/hi1910B-orangepiaipro20t.dtb"

	cat > "${debian_dir}/control" <<- EOF
		Package: ${package_name}
		Version: ${package_version}
		Section: kernel
		Priority: optional
		Architecture: arm64
		Source: linux-${kernel_release}
		Depends: linux-modules-${kernel_release}
		Maintainer: Orange Pi AI Pro 20T Armbian Builder <noreply@local>
		Description: Boot files for Orange Pi AI Pro 20T (${kernel_release})
	EOF

	cat > "${debian_dir}/postinst" <<- EOF
		#!/bin/sh
		set -e
		ln -sf "Image-${kernel_release}" /boot/Image
		exit 0
	EOF

	run_host_command_logged chmod 0755 "${debian_dir}/postinst"
	run_host_command_logged fakeroot dpkg-deb --build "${package_root}" "${image_deb}"
}

function pre_install_kernel_debs__500_opiai_install_vendor_kernel() {
	opiai__build_vendor_kernel_artifacts

	install_deb_chroot "${OPIAI_MODULES_DEB}"
	install_deb_chroot "${OPIAI_IMAGE_DEB}"

	if [[ "${INSTALL_HEADERS:-no}" == "yes" ]]; then
		install_deb_chroot "${OPIAI_HEADERS_DEB}"
	fi
}

function post_install_kernel_debs__500_opiai_set_kernel_version() {
	opiai__build_vendor_kernel_artifacts
	declare -g IMAGE_INSTALLED_KERNEL_VERSION="${OPIAI_KERNEL_RELEASE}"
	display_alert "Installed Orange Pi AI Pro 20T kernel version" "${IMAGE_INSTALLED_KERNEL_VERSION}" "info"
}

function pre_prepare_partitions__500_opiai_layout() {
	declare -g USE_HOOK_FOR_PARTITION="yes"
	declare -g IMAGE_PARTITION_TABLE="gpt"
	declare -g BOOTSIZE=0
	declare -g UEFISIZE=0
	declare -g ROOT_FS_LABEL="root_fs"
}

function prepare_image_size__500_opiai_layout() {
	local fixed_layout_mib=274
	local rootfs_target_mib
	local growth_mib
	local growth_percent

	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		growth_mib=512
		growth_percent=135
	else
		growth_mib=256
		growth_percent=120
	fi

	rootfs_target_mib=$((rootfs_size + growth_mib))
	rootfs_target_mib=$(( (rootfs_target_mib * growth_percent + 99) / 100 ))
	FIXED_IMAGE_SIZE=$(( ((fixed_layout_mib + rootfs_target_mib) + 3) / 4 * 4 ))

	display_alert "Orange Pi AI Pro 20T image size" "rootfs=${rootfs_size}MiB target=${FIXED_IMAGE_SIZE}MiB" "info"
}

function create_partition_table__500_opiai_layout() {
	local disk_reserved_sectors=2048
	local emmc_reserved_sectors=557056
	local reserved_fs_sectors=2048
	local gpt_tail_reserved_sectors=33
	local reserved_start
	local root_start
	local root_size
	local image_sectors
	local partition_script

	reserved_start=$((disk_reserved_sectors + emmc_reserved_sectors))
	root_start=$((reserved_start + reserved_fs_sectors))
	image_sectors=$(( $(stat -c%s "${SDCARD}.raw") / SECTOR_SIZE ))
	root_size=$((image_sectors - gpt_tail_reserved_sectors - root_start))

	[[ "${root_size}" -gt 0 ]] || exit_with_error "Calculated invalid root partition size" "image_sectors=${image_sectors}, root_start=${root_start}"

	partition_script=$(cat <<- EOF
		label: gpt
		1 : name="reserved_fs", start=${reserved_start}, size=${reserved_fs_sectors}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
		2 : name="root_fs", start=${root_start}, size=${root_size}, type=${PARTITION_TYPE_UUID_ROOT}
	EOF
	)

	display_alert "Orange Pi AI Pro 20T partition script" "${partition_script}" "debug"
	echo "${partition_script}" | run_host_command_logged sfdisk "${SDCARD}.raw"
}

function post_create_partitions__500_opiai_layout() {
	rootpart=2
}

function opiai__ensure_loop_partition_node() {
	local dev="${1}"
	local devname majmin maj min

	[[ -b "${dev}" ]] && return 0

	devname="$(basename "${dev}")"
	majmin="$(cat "/sys/class/block/${devname}/dev" 2>/dev/null)" || {
		display_alert "opiai: ${devname} not found in sysfs" "${dev}" "wrn"
		return 1
	}

	maj="${majmin%%:*}"
	min="${majmin##*:}"
	display_alert "opiai: creating missing device node" "${dev} (${maj}:${min})" "info"
	run_host_command_logged mknod -m0660 "${dev}" b "${maj}" "${min}"
}

function prepare_root_device__500_opiai_create_loop_nodes() {
	# Inside Docker, udevd is absent so partition device nodes may not appear in /dev
	# after partprobe. Create them directly from sysfs.
	opiai__ensure_loop_partition_node "${LOOP}p1"
	opiai__ensure_loop_partition_node "${LOOP}p2"
}

function format_partitions__500_opiai_layout() {
	# The vendor layout reserves only 1 MiB here, so use the smallest viable ext4 geometry.
	check_loop_device "${LOOP}p1"
	run_host_command_logged mkfs.ext4 -q -F -b 1024 -m 0 -O ^has_journal -L reserved_fs "${LOOP}p1"
}

function pre_update_initramfs__500_opiai_generate_initrd() {
	opiai__build_vendor_kernel_artifacts
	declare -g IMAGE_INSTALLED_KERNEL_VERSION="${OPIAI_KERNEL_RELEASE}"
	update_initramfs "${MOUNT}"
}

function pre_umount_final_image__500_opiai_populate_firmware_dir() {
	return 0
}

function post_build_image__950_opiai_write_boot_media() {
	local loop_device
	local mount_dir
	local tmp_dir
	local qemu_bin
	local aarch64_libdir
	local qemu_sysroot
	local root_part
	local root_partuuid
	local root_device_spec
	local firmware_dir
	local initrd_file
	local emmc_head
	local cleanup_done="no"

	function opiai__cleanup_post_build_image() {
		if [[ "${cleanup_done}" == "yes" ]]; then
			return 0
		fi
		cleanup_done="yes"
		if mountpoint -q "${mount_dir}" 2>/dev/null; then
			run_host_command_logged umount "${mount_dir}" || true
		fi
		if [[ -n "${loop_device:-}" ]] && losetup "${loop_device}" >/dev/null 2>&1; then
			run_host_command_logged losetup -d "${loop_device}" || true
		fi
	}

	opiai__build_vendor_kernel_artifacts

	trap opiai__cleanup_post_build_image RETURN
	loop_device="$(losetup --show --find --partscan "${FINAL_IMAGE_FILE}")" || exit_with_error "Unable to map final image" "${FINAL_IMAGE_FILE}"
	mount_dir="${EXTENSION_MANAGER_TMP_DIR}/opiai/final-image/rootfs"
	tmp_dir="${EXTENSION_MANAGER_TMP_DIR}/opiai/final-image/work"
	qemu_sysroot="${tmp_dir}/qemu-sysroot"
	root_part="${loop_device}p2"

	run_host_command_logged mkdir -p "${mount_dir}" "${tmp_dir}"
	run_host_command_logged partprobe "${loop_device}"
	run_host_command_logged mount -o ro "${root_part}" "${mount_dir}"

	firmware_dir="${tmp_dir}/fw"
	initrd_file="${mount_dir}/boot/initrd.img-${OPIAI_KERNEL_RELEASE}"
	root_partuuid="$(blkid -s PARTUUID -o value "${root_part}")"
	[[ -n "${root_partuuid}" ]] || exit_with_error "Unable to determine root PARTUUID for Orange Pi AI Pro 20T image" "${root_part}"
	root_device_spec="PARTUUID=${root_partuuid}"

	opiai__require_file "${initrd_file}"

	run_host_command_logged mkdir -p "${firmware_dir}"
	run_host_command_logged install -m 0644 "${OPIAI_IMAGE_FILE}" "${firmware_dir}/Image"
	run_host_command_logged install -m 0644 "${OPIAI_DT_IMAGE_FILE}" "${firmware_dir}/dt.img"
	run_host_command_logged install -m 0644 "${OPIAI_ITRUSTEE_FILE}" "${firmware_dir}/itrustee.img"
	run_host_command_logged install -m 0644 "${initrd_file}" "${firmware_dir}/initrd"

	emmc_head="$(opiai__emmc_head_binary)"
	opiai__require_executable "${emmc_head}"

	qemu_bin="$(opiai__find_qemu_binary)"
	aarch64_libdir="$(opiai__find_aarch64_libdir)"
	opiai__create_qemu_sysroot "${qemu_sysroot}" "${aarch64_libdir}"

	(
		cd "${tmp_dir}" || exit 1
		run_host_command_logged "${qemu_bin}" -L "${qemu_sysroot}" "${emmc_head}" "${firmware_dir}/" "${root_device_spec}" "${root_device_spec}"
	)

	opiai__require_file "${tmp_dir}/parttion_head_info"
	opiai__require_file "${tmp_dir}/boot_image_info"

	run_host_command_logged dd if="${tmp_dir}/parttion_head_info" of="${loop_device}" seek="$(opiai__partition_head_sector)" bs=512 count=2 conv=notrunc
	run_host_command_logged dd if="${tmp_dir}/parttion_head_info" of="${loop_device}" seek="$(opiai__partition_head_backup_sector)" bs=512 count=2 conv=notrunc
	run_host_command_logged dd if="${tmp_dir}/boot_image_info" of="${loop_device}" seek="$(opiai__boot_image_info_sector)" bs=512 count=8 conv=notrunc
	run_host_command_logged dd if="${OPIAI_IMAGE_FILE}" of="${loop_device}" seek="$(opiai__raw_boot_image_sector)" bs=512 conv=notrunc
	run_host_command_logged dd if="${OPIAI_IMAGE_FILE}" of="${loop_device}" seek="$(opiai__raw_boot_image_b_sector)" bs=512 conv=notrunc
	run_host_command_logged dd if="${OPIAI_DT_IMAGE_FILE}" of="${loop_device}" seek="$(opiai__raw_boot_dtb_sector)" bs=512 conv=notrunc
	run_host_command_logged dd if="${OPIAI_DT_IMAGE_FILE}" of="${loop_device}" seek="$(opiai__raw_boot_dtb_b_sector)" bs=512 conv=notrunc
	run_host_command_logged dd if="${OPIAI_ITRUSTEE_FILE}" of="${loop_device}" seek="$(opiai__raw_boot_tee_sector)" bs=512 conv=notrunc
	run_host_command_logged dd if="${OPIAI_ITRUSTEE_FILE}" of="${loop_device}" seek="$(opiai__raw_boot_tee_b_sector)" bs=512 conv=notrunc

	wait_for_disk_sync "after writing Orange Pi AI Pro 20T boot media"
	run_host_command_logged umount "${mount_dir}"
	run_host_command_logged losetup -d "${loop_device}"
	cleanup_done="yes"
	trap - RETURN
}

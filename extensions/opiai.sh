function add_host_dependencies__opiai_host_deps() {
	local gcc_major
	local cross_packages="binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu g++-aarch64-linux-gnu"

	gcc_major="$(opiai__vendor_gcc_major)"
	if [[ -n "${gcc_major}" ]]; then
		cross_packages="binutils-aarch64-linux-gnu gcc-${gcc_major}-aarch64-linux-gnu g++-${gcc_major}-aarch64-linux-gnu"
	fi

	declare -g EXTRA_BUILD_DEPS="${EXTRA_BUILD_DEPS} ${cross_packages} bc bison flex libssl-dev libelf-dev fakeroot cmake dosfstools device-tree-compiler python3-pycryptodome kmod qemu-user-static"
}

function opiai__cache_root() {
	echo "${SRC}/cache/sources/opiai"
}

function opiai__vendor_sdk_source() {
	echo "${OPIAI_SDK_SOURCE:-https://github.com/HwHiAiUser/kernel-build-opiai.git}"
}

function opiai__vendor_gcc_major() {
	local gcc_major="${OPIAI_GCC_MAJOR:-14}"

	case "${gcc_major}" in
		"" | default | system)
			echo ""
			;;
		[0-9]*)
			echo "${gcc_major}"
			;;
		*)
			exit_with_error "Unsupported Orange Pi AI Pro 20T GCC selection" "${gcc_major}; use empty/default/system or a numeric GCC major version"
			;;
	esac
}

function opiai__vendor_toolchain_label() {
	local gcc_major

	gcc_major="$(opiai__vendor_gcc_major)"
	if [[ -n "${gcc_major}" ]]; then
		echo "gcc${gcc_major}"
		return 0
	fi

	echo "gcc-default"
}

function opiai__host_image_builder_root() {
	echo "${OPIAI_IMAGE_BUILDER_ROOT:-${SRC}/../image-builder}"
}

function opiai__assets_dir() {
	echo "${OPIAI_ASSETS_DIR_OVERRIDE:-$(opiai__cache_root)/assets}"
}

function opiai__host_emmc_head_source() {
	echo "${OPIAI_EMMC_HEAD:-$(opiai__host_image_builder_root)/src/compress/download/emmc-head}"
}

function opiai__host_itrustee_source() {
	echo "${OPIAI_ITRUSTEE_IMAGE:-$(opiai__host_image_builder_root)/src/compress/download/firmware/itrustee.img}"
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
	local emmc_src
	local itrustee_src
	local emmc_dst
	local itrustee_dst

	assets_dir="$(opiai__assets_dir)"
	emmc_src="$(opiai__host_emmc_head_source)"
	itrustee_src="$(opiai__host_itrustee_source)"
	emmc_dst="$(opiai__emmc_head_binary)"
	itrustee_dst="$(opiai__itrustee_image)"

	if [[ -f "${emmc_dst}" && -f "${itrustee_dst}" ]]; then
		return 0
	fi

	opiai__require_executable "${emmc_src}"
	opiai__require_file "${itrustee_src}"

	run_host_command_logged mkdir -p "${assets_dir}"
	run_host_command_logged install -m 0755 "${emmc_src}" "${emmc_dst}"
	run_host_command_logged install -m 0644 "${itrustee_src}" "${itrustee_dst}"
}

function host_pre_docker_launch__500_opiai_stage_assets() {
	opiai__stage_vendor_assets
}

function opiai__vendor_source_dir() {
	if [[ -n "${OPIAI_SDK_ROOT:-}" ]]; then
		echo "$(realpath -m "${OPIAI_SDK_ROOT}")"
		return 0
	fi

	echo "${OPIAI_VENDOR_SOURCE_DIR_OVERRIDE:-$(opiai__cache_root)/kernel-build-opiai/$(branch2dir "$(opiai__branch_to_vendor_ref)")}"
}

function opiai__vendor_board_dts_file() {
	echo "$(opiai__vendor_source_dir)/dtb/dts/hi1910b/hi1910BL/hi1910B-orangepiaipro20t.dts"
}

function opiai__vendor_kernel_defconfig_file() {
	echo "$(opiai__vendor_source_dir)/linux-source/arch/arm64/configs/ascend310B_defconfig"
}

function opiai__update_vendor_submodules() {
	local sdk_root="${1}"

	opiai__require_directory "${sdk_root}"
	opiai__require_directory "${sdk_root}/.git"
	opiai__require_file "${sdk_root}/.gitmodules"

	run_host_command_logged git -C "${sdk_root}" submodule sync --recursive
	run_host_command_logged git -C "${sdk_root}" submodule update --init --recursive --jobs "$(opiai__vendor_jobs_count)"
}

function opiai__reset_cached_vendor_source_tree() {
	local sdk_root="${1}"
	local kernel_root="${sdk_root}/linux-source"

	opiai__require_directory "${sdk_root}"
	opiai__require_directory "${sdk_root}/.git"
	opiai__require_directory "${kernel_root}"
	opiai__require_directory "${kernel_root}/.git"

	display_alert "Resetting Orange Pi AI Pro 20T cached vendor tree" "${sdk_root}" "info"
	run_host_command_logged git -C "${sdk_root}" reset --hard HEAD
	run_host_command_logged git -C "${sdk_root}" clean -xfd
	run_host_command_logged git -C "${kernel_root}" reset --hard HEAD
	run_host_command_logged git -C "${kernel_root}" clean -xfd
}

function opiai__prepare_vendor_source_tree() {
	local sdk_root
	local vendor_ref

	sdk_root="$(opiai__vendor_source_dir)"
	vendor_ref="$(opiai__branch_to_vendor_ref)"

	if [[ -n "${OPIAI_SDK_ROOT:-}" ]]; then
		opiai__require_directory "${sdk_root}"
		opiai__require_directory "${sdk_root}/.git"
		opiai__update_vendor_submodules "${sdk_root}"
		opiai__require_directory "${sdk_root}/linux-source"
		declare -g OPIAI_PREPARED_VENDOR_SOURCE_DIR="${sdk_root}"
		return 0
	fi

	fetch_from_repo "$(opiai__vendor_sdk_source)" "opiai/kernel-build-opiai" "${vendor_ref}" "yes"

	opiai__require_directory "${sdk_root}"
	opiai__require_directory "${sdk_root}/.git"
	opiai__update_vendor_submodules "${sdk_root}"
	opiai__reset_cached_vendor_source_tree "${sdk_root}"
	opiai__require_directory "${sdk_root}/linux-source"
	declare -g OPIAI_PREPARED_VENDOR_SOURCE_DIR="${sdk_root}"
}

function opiai__patch_vendor_source_tree() {
	local dts_file
	local dts_file_quoted

	dts_file="$(opiai__vendor_board_dts_file)"
	opiai__require_file "${dts_file}"
	printf -v dts_file_quoted '%q' "${dts_file}"

	run_host_command_logged "
		dts_file=${dts_file_quoted}
		if grep -q 'systemd\\.unified_cgroup_hierarchy=0' \"\${dts_file}\"; then
			sed -i 's/ systemd\\.unified_cgroup_hierarchy=0//g' \"\${dts_file}\"
		fi
		if grep -q 'systemd\\.unified_cgroup_hierarchy=0' \"\${dts_file}\"; then
			exit 1
		fi
	"
}

function opiai__vendor_build_dir() {
	echo "${OPIAI_VENDOR_BUILD_DIR_OVERRIDE:-$(opiai__cache_root)/build/${BRANCH}/$(opiai__vendor_toolchain_label)}"
}

function opiai__vendor_package_version() {
	if [[ -n "${OPIAI_PACKAGE_VERSION:-}" ]]; then
		echo "${OPIAI_PACKAGE_VERSION}"
		return 0
	fi

	date '+%Y%m%d%H%M'
}

function opiai__vendor_jobs_count() {
	local jobs="${CTHREADS:-}"

	if [[ "${jobs}" =~ ^-j([0-9]+)$ ]]; then
		echo "${BASH_REMATCH[1]}"
		return 0
	fi

	if [[ "${jobs}" =~ ^[0-9]+$ ]]; then
		echo "${jobs}"
		return 0
	fi

	nproc
}

function opiai__find_prefixed_tool() {
	local tool_name="${1}"
	local candidate="aarch64-linux-gnu-${tool_name}"

	if command -v "${candidate}" >/dev/null 2>&1; then
		command -v "${candidate}"
		return 0
	fi

	return 1
}

function opiai__find_versioned_prefixed_tool() {
	local tool_name="${1}"
	local gcc_major
	local candidate

	gcc_major="$(opiai__vendor_gcc_major)"
	if [[ -z "${gcc_major}" ]]; then
		opiai__find_prefixed_tool "${tool_name}"
		return 0
	fi

	candidate="aarch64-linux-gnu-${tool_name}-${gcc_major}"
	if command -v "${candidate}" >/dev/null 2>&1; then
		command -v "${candidate}"
		return 0
	fi

	return 1
}

function opiai__find_best_prefixed_tool() {
	local tool_name="${1}"

	if opiai__find_versioned_prefixed_tool "${tool_name}" >/dev/null 2>&1; then
		opiai__find_versioned_prefixed_tool "${tool_name}"
		return 0
	fi

	opiai__find_prefixed_tool "${tool_name}"
}

function opiai__prepare_vendor_cross_toolchain() {
	local build_dir="${1}"
	local shim_dir="${build_dir}/toolchain/bin"
	local tool_name
	local tool_path
	local gcc_path
	local gcc_major_suffix=""

	if [[ -n "$(opiai__vendor_gcc_major)" ]]; then
		gcc_major_suffix="-$(opiai__vendor_gcc_major)"
	fi

	run_host_command_logged mkdir -p "${shim_dir}"

	for tool_name in gcc cpp g++; do
		tool_path="$(opiai__find_versioned_prefixed_tool "${tool_name}")" || \
			exit_with_error "Missing requested Orange Pi AI Pro 20T cross compiler frontend" "aarch64-linux-gnu-${tool_name}${gcc_major_suffix}"
		run_host_command_logged ln -snf "${tool_path}" "${shim_dir}/aarch64-linux-gnu-${tool_name}"
	done

	for tool_name in ar as ld nm objcopy objdump ranlib readelf strip gcc-ar gcc-nm gcc-ranlib; do
		if tool_path="$(opiai__find_best_prefixed_tool "${tool_name}")"; then
			run_host_command_logged ln -snf "${tool_path}" "${shim_dir}/aarch64-linux-gnu-${tool_name}"
		fi
	done

	gcc_path="$(readlink -f "${shim_dir}/aarch64-linux-gnu-gcc")"
	display_alert "Orange Pi AI Pro 20T vendor cross compiler" "${gcc_path}" "info"
	declare -g OPIAI_VENDOR_CROSS_COMPILE_PREFIX="${shim_dir}/aarch64-linux-gnu-"
}

function opiai__ensure_driver_modules_autoload_conf() {
	local output_dir="${1}"
	local driver_modules_dir="${output_dir}/driver_modules"
	local autoload_conf="${output_dir}/ascend310b-driver-modules.conf"
	local driver_modules_dir_quoted
	local autoload_conf_quoted

	[[ -f "${autoload_conf}" ]] && return 0
	[[ -d "${driver_modules_dir}" ]] || return 0
	printf -v driver_modules_dir_quoted '%q' "${driver_modules_dir}"
	printf -v autoload_conf_quoted '%q' "${autoload_conf}"

	run_host_command_logged "
		driver_modules_dir=${driver_modules_dir_quoted}
		autoload_conf=${autoload_conf_quoted}
		mapfile -t module_names < <(find \"\${driver_modules_dir}\" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | sed 's/\\.ko\$//' | sort -u)
		[[ \${#module_names[@]} -gt 0 ]] || exit 0
		printf '%s\n' \"\${module_names[@]}\" > \"\${autoload_conf}\"
	"
}

function opiai__compress_module_tree() {
	local modules_dir="${1}"
	local strip_bin="${2:-}"
	local shell_script
	local modules_dir_quoted
	local strip_bin_quoted

	[[ -d "${modules_dir}" ]] || return 0
	printf -v modules_dir_quoted '%q' "${modules_dir}"
	printf -v strip_bin_quoted '%q' "${strip_bin}"

	shell_script="modules_dir=${modules_dir_quoted}; strip_bin=${strip_bin_quoted}; mapfile -d '' -t module_paths < <(find \"\${modules_dir}\" -type f -name '*.ko' -print0); [[ \${#module_paths[@]} -gt 0 ]] || exit 0; for module_path in \"\${module_paths[@]}\"; do if [[ -n \"\${strip_bin}\" && -x \"\${strip_bin}\" ]]; then \"\${strip_bin}\" --strip-debug \"\${module_path}\"; fi; xz --check=crc32 --lzma2=dict=1MiB -f \"\${module_path}\"; done"
	run_host_command_logged "${shell_script}"
}

function opiai__postprocess_vendor_modules() {
	local output_dir="${1}"
	local kernel_release="${2}"
	local kernel_modules_dir="${output_dir}/modules/lib/modules/${kernel_release}"
	local driver_modules_dir="${output_dir}/driver_modules"
	local strip_bin="${OPIAI_VENDOR_CROSS_COMPILE_PREFIX}strip"

	opiai__ensure_driver_modules_autoload_conf "${output_dir}"
	opiai__compress_module_tree "${kernel_modules_dir}" ""
	opiai__compress_module_tree "${driver_modules_dir}" "${strip_bin}"
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

function opiai__prepare_vendor_worktree() {
	opiai__prepare_vendor_source_tree
}

function opiai__load_vendor_kernel_artifacts() {
	local sdk_root
	local build_dir
	local output_dir
	local workspace_dir
	local kernel_release
	local modules_deb
	local headers_deb=""
	local dtb_file
	local image_deb

	opiai__stage_vendor_assets
	sdk_root="$(opiai__vendor_source_dir)"
	build_dir="$(opiai__vendor_build_dir)"
	output_dir="${build_dir}/output"
	workspace_dir="${build_dir}/workspace"

	[[ -d "${output_dir}" ]] || return 1
	[[ -d "${workspace_dir}" ]] || return 1

	kernel_release="$(find "${output_dir}/modules/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -n 1)"
	[[ -n "${kernel_release}" ]] || return 1

	modules_deb="$(find "${output_dir}" -maxdepth 1 -type f -name "linux-modules-${kernel_release}_*.deb" | sort | head -n 1)"
	[[ -n "${modules_deb}" && -f "${modules_deb}" ]] || return 1

	if [[ "${INSTALL_HEADERS:-no}" == "yes" ]]; then
		headers_deb="$(find "${output_dir}" -maxdepth 1 -type f -name "linux-headers-${kernel_release}_*.deb" | sort | head -n 1)"
		[[ -n "${headers_deb}" && -f "${headers_deb}" ]] || return 1
	fi

	dtb_file="${workspace_dir}/dtb/dtbs/hi1910B-orangepiaipro20t.dtb"
	[[ -f "${dtb_file}" ]] || return 1
	[[ -f "${output_dir}/Image" ]] || return 1
	[[ -f "${output_dir}/dt.img" ]] || return 1

	image_deb="$(find "${output_dir}" -maxdepth 1 -type f -name "linux-image-${BRANCH}-${LINUXFAMILY}_*.deb" | sort | head -n 1)"
	[[ -n "${image_deb}" && -f "${image_deb}" ]] || return 1
	[[ -f "${sdk_root}/linux-source/arch/arm64/configs/ascend310B_defconfig" ]] || return 1
	[[ -f "$(opiai__itrustee_image)" ]] || return 1

	declare -g OPIAI_VENDOR_WORKTREE_DIR="${sdk_root}"
	declare -g OPIAI_VENDOR_BUILD_DIR="${build_dir}"
	declare -g OPIAI_VENDOR_OUTPUT_DIR="${output_dir}"
	declare -g OPIAI_KERNEL_RELEASE="${kernel_release}"
	declare -g OPIAI_MODULES_DEB="${modules_deb}"
	declare -g OPIAI_HEADERS_DEB="${headers_deb}"
	declare -g OPIAI_IMAGE_DEB="${image_deb}"
	declare -g OPIAI_IMAGE_FILE="${output_dir}/Image"
	declare -g OPIAI_DT_IMAGE_FILE="${output_dir}/dt.img"
	declare -g OPIAI_DTB_FILE="${dtb_file}"
	declare -g OPIAI_ITRUSTEE_FILE="$(opiai__itrustee_image)"
	declare -g OPIAI_ARTIFACTS_READY="yes"
	return 0
}

function opiai__build_vendor_kernel_artifacts() {
	local sdk_root
	local worktree_dir
	local build_dir
	local output_dir
	local workspace_dir
	local kernel_release
	local modules_deb
	local headers_deb=""
	local dtb_file
	local image_deb
	local package_version
	local -a vendor_make_args

	if opiai__load_vendor_kernel_artifacts; then
		display_alert "Reusing Orange Pi AI Pro 20T vendor kernel artifacts" "$(opiai__vendor_build_dir)" "info"
		return 0
	fi

	if [[ "${OPIAI_ARTIFACTS_READY:-no}" == "yes" ]]; then
		exit_with_error "Requested prebuilt Orange Pi AI Pro 20T vendor artifacts but cache is incomplete" "$(opiai__vendor_build_dir)"
	fi

	opiai__stage_vendor_assets
	sdk_root="$(opiai__vendor_source_dir)"
	opiai__prepare_vendor_worktree
	opiai__patch_vendor_source_tree
	worktree_dir="${OPIAI_PREPARED_VENDOR_SOURCE_DIR}"
	build_dir="$(opiai__vendor_build_dir)"
	output_dir="${build_dir}/output"
	workspace_dir="${build_dir}/workspace"

	opiai__require_file "$(opiai__itrustee_image)"
	opiai__require_file "${sdk_root}/linux-source/arch/arm64/configs/ascend310B_defconfig"
	opiai__require_file "${sdk_root}/linux-source/certs/ELF_Common_RSA4096_CN_20191009_Huawei.pem"

	run_host_command_logged mkdir -p "${build_dir}"
	run_host_command_logged rm -rf "${output_dir}" "${workspace_dir}"
	opiai__prepare_vendor_cross_toolchain "${build_dir}"
		vendor_make_args=(
			-C "${worktree_dir}"
			OUTPUT_DIR="${output_dir}"
			WORKSPACE_DIR="${workspace_dir}"
			CROSS_COMPILE_PREFIX="${OPIAI_VENDOR_CROSS_COMPILE_PREFIX}"
			JOBS="$(opiai__vendor_jobs_count)"
			SKIP_MENUCONFIG=1
			INSTALL_MOD_STRIP=1
			CONFIG_MODULE_COMPRESS=y
			CONFIG_MODULE_COMPRESS_XZ=y
			CONFIG_MODULE_COMPRESS_ALL=y
		)

		display_alert "Building Orange Pi AI Pro 20T vendor kernel artifacts" "${BRANCH} -> $(opiai__branch_to_vendor_ref)" "info"

		run_host_command_logged make "${vendor_make_args[@]}" kernel dtb driver

		kernel_release="$(find "${output_dir}/modules/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)"
		[[ -n "${kernel_release}" ]] || exit_with_error "Unable to determine built kernel release" "${output_dir}/modules/lib/modules"

		opiai__postprocess_vendor_modules "${output_dir}" "${kernel_release}"

		run_host_command_logged make "${vendor_make_args[@]}" modules-deb

		if [[ "${INSTALL_HEADERS:-no}" == "yes" ]]; then
			run_host_command_logged make "${vendor_make_args[@]}" headers-deb
		fi

		modules_deb="$(find "${output_dir}" -maxdepth 1 -type f -name "linux-modules-${kernel_release}_*.deb" | sort | head -n 1)"
		[[ -n "${modules_deb}" ]] || exit_with_error "Unable to locate vendor modules deb" "${output_dir}"

	if [[ "${INSTALL_HEADERS:-no}" == "yes" ]]; then
		headers_deb="$(find "${output_dir}" -maxdepth 1 -type f -name "linux-headers-${kernel_release}_*.deb" | sort | head -n 1)"
		[[ -n "${headers_deb}" ]] || exit_with_error "Unable to locate vendor headers deb" "${output_dir}"
	fi

	dtb_file="${workspace_dir}/dtb/dtbs/hi1910B-orangepiaipro20t.dtb"
	opiai__require_file "${dtb_file}"
	opiai__require_file "${output_dir}/Image"
	opiai__require_file "${output_dir}/dt.img"

	package_version="$(opiai__vendor_package_version)"
	image_deb="${output_dir}/linux-image-${BRANCH}-${LINUXFAMILY}_${package_version}_arm64.deb"

	opiai__build_vendor_image_deb "${worktree_dir}" "${output_dir}" "${kernel_release}" "${dtb_file}" "${image_deb}" "${package_version}"

	declare -g OPIAI_VENDOR_WORKTREE_DIR="${worktree_dir}"
	declare -g OPIAI_VENDOR_BUILD_DIR="${build_dir}"
	declare -g OPIAI_VENDOR_OUTPUT_DIR="${output_dir}"
	declare -g OPIAI_KERNEL_RELEASE="${kernel_release}"
	declare -g OPIAI_MODULES_DEB="${modules_deb}"
	declare -g OPIAI_HEADERS_DEB="${headers_deb}"
	declare -g OPIAI_IMAGE_DEB="${image_deb}"
	declare -g OPIAI_IMAGE_FILE="${output_dir}/Image"
	declare -g OPIAI_DT_IMAGE_FILE="${output_dir}/dt.img"
	declare -g OPIAI_DTB_FILE="${dtb_file}"
	declare -g OPIAI_ITRUSTEE_FILE="$(opiai__itrustee_image)"
	declare -g OPIAI_ARTIFACTS_READY="yes"
}

function opiai__build_vendor_image_deb() {
	local worktree_dir="${1}"
	local output_dir="${2}"
	local kernel_release="${3}"
	local dtb_file="${4}"
	local image_deb="${5}"
	local package_version="${6}"
	local package_name="linux-image-${BRANCH}-${LINUXFAMILY}"
	local package_root="${output_dir}/image-deb/pkgroot"
	local image_dir="/usr/lib/linux-image-${kernel_release}"
	local debian_dir="${package_root}/DEBIAN"

	run_host_command_logged rm -rf "${output_dir}/image-deb"
	run_host_command_logged mkdir -p "${debian_dir}" \
		"${package_root}/boot/dtb/hi1910b" \
		"${package_root}${image_dir}/hi1910b"

	run_host_command_logged install -m 0644 "${output_dir}/Image" "${package_root}/boot/Image-${kernel_release}"
	run_host_command_logged install -m 0644 "${dtb_file}" "${package_root}/boot/dtb/hi1910b/hi1910B-orangepiaipro20t.dtb"
	run_host_command_logged install -m 0644 "${dtb_file}" "${package_root}${image_dir}/hi1910b/hi1910B-orangepiaipro20t.dtb"

	if [[ -f "${worktree_dir}/linux-source/System.map" ]]; then
		run_host_command_logged install -m 0644 "${worktree_dir}/linux-source/System.map" "${package_root}/boot/System.map-${kernel_release}"
	fi

	run_host_command_logged install -m 0644 "${worktree_dir}/linux-source/.config" "${package_root}/boot/config-${kernel_release}"

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

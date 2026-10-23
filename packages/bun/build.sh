TERMUX_PKG_HOMEPAGE=https://bun.com
TERMUX_PKG_DESCRIPTION="Incredibly fast JavaScript runtime, bundler, test runner, and package manager"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="Gouranga Das Samrat <gouranga.das.khulna@gmail.com>"
TERMUX_PKG_VERSION="1.4.4"
TERMUX_PKG_SRCURL=git+https://github.com/oven-sh/bun
TERMUX_PKG_GIT_BRANCH="bun-v$TERMUX_PKG_VERSION"
TERMUX_PKG_EXCLUDED_ARCHES="arm, i686"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_AUTO_UPDATE=true

termux_pkg_auto_update() {
	local TERMUX_SETUP_BUN="${TERMUX_SCRIPTDIR}/scripts/build/setup/termux_setup_bun.sh"
	local latest_tag latest_version
	latest_tag="$(termux_github_api_get_tag)"
	latest_version="${latest_tag#bun-v}"

	if [[ "${latest_version}" == "${TERMUX_PKG_VERSION}" ]]; then
		echo "INFO: No update needed. Already at version '${TERMUX_PKG_VERSION}'."
		return
	fi

	# Get the SHA256 checksum from the release artifacts
	local TERMUX_BUN_SHA256
	TERMUX_BUN_SHA256="$(
		curl -sL \
			-H "X-GitHub-Api-Version: 2026-03-10" \
			-H "Accept: application/vnd.github+json" \
			-A "Termux update checker 1.1 (github.com/termux/termux-packages)" \
			"https://api.github.com/repos/oven-sh/bun/releases/tags/${latest_tag}" \
		| jq -r '.[].[]? | select(.name? == "bun-linux-x64.zip") | .digest | ltrimstr("sha256:")'
	)"

	if [[ ! "${TERMUX_BUN_SHA256:-}" =~ [0-9a-f]{64} ]]; then
		printf '%s\n' \
			"Could not fetch valid SHA256 sum from upstream release artifacts." \
			"Got: '${TERMUX_BUN_SHA256:-}'" >&2
		return
	fi

	printf '%s\n' \
		"" \
		"Toolchain:" \
		"bun-linux-x64.zip  $TERMUX_BUN_SHA256" \
		""

	if [[ "${BUILD_PACKAGES}" == "false" ]]; then
		echo "INFO: package needs to be updated to ${latest_version}."
		return
	fi

	# Update the version and checksum in termux_setup_bun
	sed \
		-e "s|local TERMUX_BUN_VERSION=.*|local TERMUX_BUN_VERSION=\"\${TERMUX_BUN_VERSION:-${latest_version}}\"|" \
		-e "s|local TERMUX_BUN_SHA256=.*|local TERMUX_BUN_SHA256=\"${TERMUX_BUN_SHA256}\"|" \
		-i "${TERMUX_SETUP_BUN}"

	termux_pkg_upgrade_version "${latest_version}"
}

termux_step_make() {
	termux_setup_cmake
	termux_setup_ninja
	termux_setup_rust
	termux_setup_bun

	local llvm_ver="23.1.1"
	local host_machine
	host_machine="$(uname -m)"
	local llvm_arch
	local llvm_sha
	local icu_arch
	local icu_sha
	local icu_url_base="http://archive.ubuntu.com/ubuntu/pool/main/i/icu"

	case "${host_machine}" in
		aarch64|arm64)
			llvm_arch="ARM64"
			llvm_sha="3fbaaa6a1f147557a4095b9911f8dc2d4c745a11863982f76ee20e248c190a80"
			icu_arch="arm64"
			icu_sha="ac68372cf4a976e6a206858fd9b28c68e49d37d650b9b8653270038a6e7bc174"
			icu_url_base="http://ports.ubuntu.com/ubuntu-ports/pool/main/i/icu"
			;;
		x86_64|amd64)
			llvm_arch="X64"
			llvm_sha="832aeb58d105de1cabc7b982dd2c65de0610f7377df48ae8fc2dd8e97420a15c"
			icu_arch="amd64"
			icu_sha="58a154f6307289813da2276f900498ef536ae7c0522d2cf31a3c3c5cf62dfd9a"
			;;
		*)
			termux_error_exit "Unsupported host architecture for LLVM toolchain: ${host_machine}"
			;;
	esac

	local llvm_tar="LLVM-${llvm_ver}-Linux-${llvm_arch}.tar.xz"
	local llvm_dir="$TERMUX_PKG_BUILDDIR/llvm-toolchain"
	local icu_deb="libicu70_70.1-2_${icu_arch}.deb"

	if [[ ! -d "$llvm_dir" ]]; then
		termux_download \
			"https://github.com/llvm/llvm-project/releases/download/llvmorg-${llvm_ver}/${llvm_tar}" \
			"$TERMUX_PKG_CACHEDIR/$llvm_tar" \
			"$llvm_sha"
		mkdir -p "$llvm_dir"
		tar -xf "$TERMUX_PKG_CACHEDIR/$llvm_tar" -C "$llvm_dir" --strip-components=1

		termux_download \
			"${icu_url_base}/${icu_deb}" \
			"$TERMUX_PKG_CACHEDIR/$icu_deb" \
			"$icu_sha"
		local icu_tmp="$TERMUX_PKG_BUILDDIR/icu-tmp"
		mkdir -p "$icu_tmp"
		ar x "$TERMUX_PKG_CACHEDIR/$icu_deb" --output "$icu_tmp"
		tar -xf "$icu_tmp"/data.tar.* -C "$icu_tmp"
		cp -P "$icu_tmp"/usr/lib/*-linux-gnu*/libicu*.so* "$llvm_dir/lib/" 2>/dev/null || \
			cp -P "$icu_tmp"/usr/lib/libicu*.so* "$llvm_dir/lib/"
		rm -rf "$icu_tmp"
	fi

	export BUN_TOOLCHAIN_LLVM="$llvm_dir"
	export PATH="$BUN_TOOLCHAIN_LLVM/bin:$PATH"
	export LD_LIBRARY_PATH="$llvm_dir/lib:${LD_LIBRARY_PATH:-}"

	local _bun_arch="$TERMUX_ARCH"
	if [[ "$TERMUX_ARCH" == "x86_64" ]]; then
		_bun_arch="x64"
	fi

	# WebKit prebuilt archives were built with NDK r27c (offset 0xE8 for has_val).
	# NDK r30 packs has_val into tail padding at 0xE2 unless __put_flag_in_tail is false.
	find "$NDK" -type f -path "*/c++/v1/__expected/expected.h" -exec sed -i \
		's/__fits_in_tail_padding<__union_t, bool>/false/g' {} +

	rustup toolchain install
	bun run build:release \
		--abi=android \
		--arch="$_bun_arch" \
		--android-ndk="$NDK" \
		--canary=false \
		--lto=on
}

termux_step_make_install() {
	install -Dm755 "$TERMUX_PKG_SRCDIR/build/release/bun" "$TERMUX_PREFIX/bin/bun"
	ln -sf bun "$TERMUX_PREFIX/bin/bunx"

	install -Dm644 "$TERMUX_PKG_SRCDIR/completions/bun.bash" \
		"$TERMUX_PREFIX/share/bash-completion/completions/bun"
	install -Dm644 "$TERMUX_PKG_SRCDIR/completions/bun.zsh" \
		"$TERMUX_PREFIX/share/zsh/site-functions/_bun"
	install -Dm644 "$TERMUX_PKG_SRCDIR/completions/bun.fish" \
		"$TERMUX_PREFIX/share/fish/vendor_completions.d/bun.fish"
}

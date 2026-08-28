#!/bin/sh

set -eu

readonly rootfs_target=/work/rootfs
readonly artifacts_target=/work/artifacts
readonly source=/work/guest

rootfs="$(mktemp -d /work/.rootfs.XXXXXX)"
artifacts="$(mktemp -d /work/.artifacts.XXXXXX)"
rootfs_backup=
artifacts_backup=
rootfs_old_moved=false
rootfs_new_moved=false
artifacts_old_moved=false
artifacts_new_moved=false
publication_committed=false

cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ "${publication_committed}" != true ]; then
        if [ "${artifacts_new_moved}" = true ]; then
            rm -rf "${artifacts_target}"
        fi
        if [ "${artifacts_old_moved}" = true ] && [ -d "${artifacts_backup}" ]; then
            mv "${artifacts_backup}" "${artifacts_target}"
        fi
        if [ "${rootfs_new_moved}" = true ]; then
            rm -rf "${rootfs_target}"
        fi
        if [ "${rootfs_old_moved}" = true ] && [ -d "${rootfs_backup}" ]; then
            mv "${rootfs_backup}" "${rootfs_target}"
        fi
    fi
    if [ -n "${rootfs}" ]; then
        rm -rf "${rootfs}"
    fi
    if [ -n "${artifacts}" ]; then
        rm -rf "${artifacts}"
    fi
    if [ -n "${rootfs_backup}" ]; then
        rm -rf "${rootfs_backup}"
    fi
    if [ -n "${artifacts_backup}" ]; then
        rm -rf "${artifacts_backup}"
    fi
    exit "${result}"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

apk \
    --root "${rootfs}" \
    --keys-dir /etc/apk/keys \
    --initdb \
    --no-cache \
    --repository https://dl-cdn.alpinelinux.org/alpine/v3.22/main \
    --repository https://dl-cdn.alpinelinux.org/alpine/v3.22/community \
    add \
        alpine-base=3.22.5-r0 \
        dbus=1.16.2-r1 \
        font-dejavu=2.37-r6 \
        linux-virt=6.12.103-r0 \
        openbox=3.6.1-r8 \
        spice-vdagent=0.22.1-r2 \
        spice-webdavd=3.0-r4 \
        xclip=0.13-r3 \
        xorg-server=21.1.19-r0 \
        xrandr=1.5.2-r0 \
        xsetroot=1.1.3-r1 \
        xterm=399-r0

install -m 0755 "${source}/init" "${rootfs}/init"
install -d -m 0755 "${rootfs}/etc/X11" "${rootfs}/usr/local/bin"
install -m 0644 "${source}/xorg.conf" "${rootfs}/etc/X11/xorg.conf"
install -m 0755 "${source}/static-desktop.sh" "${rootfs}/usr/local/bin/static-desktop.sh"
install -m 0755 "${source}/animation-load.sh" "${rootfs}/usr/local/bin/animation-load.sh"
install -m 0755 "${source}/animation-generator.sh" "${rootfs}/usr/local/bin/animation-generator.sh"

cp "${rootfs}/boot/vmlinuz-virt" "${artifacts}/vmlinuz-virt"
(
    cd "${rootfs}"
    find . -print | cpio -o -H newc 2>/dev/null | gzip -9 > "${artifacts}/perf-initramfs.cpio.gz"
)

installed_version() {
    package="$1"
    awk -v package="${package}" '
        $0 == "P:" package { found = 1; next }
        found && /^V:/ { print substr($0, 3); exit }
        found && NF == 0 { exit }
    ' "${rootfs}/lib/apk/db/installed"
}

record_package() {
    package="$1"
    key="$2"
    version="$(installed_version "${package}")"
    if [ -z "${version}" ]; then
        echo "Installed package version is unavailable: ${package}" >&2
        exit 1
    fi
    printf '%s=%s\n' "${key}" "${version}"
}

manifest="${artifacts}/build-manifest.env"
kernel_version="$(installed_version linux-virt)"
if [ -z "${kernel_version}" ]; then
    echo "Installed linux-virt version is unavailable." >&2
    exit 1
fi
{
    echo 'manifest_version=1'
    printf 'guest_kernel=linux-virt-%s\n' "${kernel_version}"
    record_package alpine-base guest_alpine_base
    record_package dbus guest_dbus
    record_package font-dejavu guest_font_dejavu
    record_package linux-virt guest_linux_virt
    record_package openbox guest_openbox
    record_package spice-vdagent guest_spice_vdagent
    record_package spice-webdavd guest_spice_webdavd
    record_package xclip guest_xclip
    record_package xorg-server guest_xorg_server
    record_package xrandr guest_xrandr
    record_package xsetroot guest_xsetroot
    record_package xterm guest_xterm
    printf 'guest_kernel_sha256=%s\n' "$(sha256sum "${artifacts}/vmlinuz-virt" | awk '{print $1}')"
    printf 'guest_initramfs_sha256=%s\n' "$(sha256sum "${artifacts}/perf-initramfs.cpio.gz" | awk '{print $1}')"
} > "${manifest}"

if [ "$(grep -c '^manifest_version=1$' "${manifest}")" -ne 1 ] \
    || [ "$(grep -c '^guest_kernel_sha256=[0-9a-f]\{64\}$' "${manifest}")" -ne 1 ] \
    || [ "$(grep -c '^guest_initramfs_sha256=[0-9a-f]\{64\}$' "${manifest}")" -ne 1 ]; then
    echo "Generated guest build manifest is incomplete." >&2
    exit 1
fi
expected_kernel_sha256="$(sed -n 's/^guest_kernel_sha256=//p' "${manifest}")"
expected_initramfs_sha256="$(sed -n 's/^guest_initramfs_sha256=//p' "${manifest}")"
actual_kernel_sha256="$(sha256sum "${artifacts}/vmlinuz-virt" | awk '{print $1}')"
actual_initramfs_sha256="$(sha256sum "${artifacts}/perf-initramfs.cpio.gz" | awk '{print $1}')"
if [ "${actual_kernel_sha256}" != "${expected_kernel_sha256}" ] \
    || [ "${actual_initramfs_sha256}" != "${expected_initramfs_sha256}" ]; then
    echo "Generated guest artifacts do not match the build manifest." >&2
    exit 1
fi

printf 'guest kernel: '
echo "linux-virt-${kernel_version}"
du -h \
    "${artifacts}/vmlinuz-virt" \
    "${artifacts}/perf-initramfs.cpio.gz" \
    "${manifest}"

# Publish only after APK installation, manifest generation, and artifact hash
# verification have all succeeded. The EXIT trap restores both old directories
# if either rename fails or the process is interrupted before the commit point.
if [ -e "${rootfs_target}" ]; then
    rootfs_backup="$(mktemp -d /work/.rootfs-backup.XXXXXX)"
    rmdir "${rootfs_backup}"
    rootfs_old_moved=true
    mv "${rootfs_target}" "${rootfs_backup}"
fi
rootfs_new_moved=true
mv "${rootfs}" "${rootfs_target}"
rootfs=

if [ -e "${artifacts_target}" ]; then
    artifacts_backup="$(mktemp -d /work/.artifacts-backup.XXXXXX)"
    rmdir "${artifacts_backup}"
    artifacts_old_moved=true
    mv "${artifacts_target}" "${artifacts_backup}"
fi
artifacts_new_moved=true
mv "${artifacts}" "${artifacts_target}"
artifacts=
publication_committed=true

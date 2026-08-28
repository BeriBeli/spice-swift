#!/bin/sh

set -u

xinput_list_file="${PERF_XINPUT_LIST_FILE:-}"
xorg_log="${PERF_XORG_LOG:-/tmp/Xorg.0.log}"
kernel_devices="${PERF_INPUT_DEVICES_FILE:-/proc/bus/input/devices}"
xinput_output="${TMPDIR:-/tmp}/swiftspice-input-diagnostic-xinput.$$"
xorg_output="${TMPDIR:-/tmp}/swiftspice-input-diagnostic-xorg.$$"
kernel_output="${TMPDIR:-/tmp}/swiftspice-input-diagnostic-kernel.$$"

cleanup() {
    rm -f "${xinput_output}" "${xorg_output}" "${kernel_output}"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

echo "PERF_INPUT_DIAGNOSTIC_BEGIN"

if test -n "${xinput_list_file}"; then
    if test -r "${xinput_list_file}"; then
        if cp "${xinput_list_file}" "${xinput_output}" 2>/dev/null; then
            xinput_status=0
        else
            : > "${xinput_output}"
            xinput_status=74
        fi
    else
        : > "${xinput_output}"
        xinput_status=66
    fi
elif xinput --list --short > "${xinput_output}" 2>&1; then
    xinput_status=0
else
    xinput_status=$?
fi
if test -s "${xinput_output}"; then
    line=
    while IFS= read -r line || test -n "${line}"; do
        printf 'PERF_INPUT_DIAGNOSTIC source=xinput text=%s\n' "${line}"
    done < "${xinput_output}"
elif test "${xinput_status}" -eq 66; then
    echo "PERF_INPUT_DIAGNOSTIC source=xinput text=<missing>"
elif test "${xinput_status}" -ne 0; then
    printf 'PERF_INPUT_DIAGNOSTIC source=xinput text=<command_failed code=%s>\n' \
        "${xinput_status}"
else
    echo "PERF_INPUT_DIAGNOSTIC source=xinput text=<empty>"
fi

if test -r "${xorg_log}"; then
    if grep -Ei 'input|libinput|keyboard|mouse|tablet' "${xorg_log}" \
        > "${xorg_output}" 2>&1; then
        xorg_status=0
    else
        xorg_status=$?
    fi
    if test -s "${xorg_output}"; then
        line=
        while IFS= read -r line || test -n "${line}"; do
            printf 'PERF_INPUT_DIAGNOSTIC source=xorg text=%s\n' "${line}"
        done < "${xorg_output}"
    elif test "${xorg_status}" -gt 1; then
        printf 'PERF_INPUT_DIAGNOSTIC source=xorg text=<read_failed code=%s>\n' \
            "${xorg_status}"
    else
        echo "PERF_INPUT_DIAGNOSTIC source=xorg text=<empty>"
    fi
else
    echo "PERF_INPUT_DIAGNOSTIC source=xorg text=<missing>"
fi

if test -r "${kernel_devices}"; then
    if grep -E '^(N: Name=|H: Handlers=)' "${kernel_devices}" \
        > "${kernel_output}" 2>&1; then
        kernel_status=0
    else
        kernel_status=$?
    fi
    if test -s "${kernel_output}"; then
        line=
        while IFS= read -r line || test -n "${line}"; do
            printf 'PERF_INPUT_DIAGNOSTIC source=proc_input text=%s\n' "${line}"
        done < "${kernel_output}"
    elif test "${kernel_status}" -gt 1; then
        printf 'PERF_INPUT_DIAGNOSTIC source=proc_input text=<read_failed code=%s>\n' \
            "${kernel_status}"
    else
        echo "PERF_INPUT_DIAGNOSTIC source=proc_input text=<empty>"
    fi
else
    echo "PERF_INPUT_DIAGNOSTIC source=proc_input text=<missing>"
fi

echo "PERF_INPUT_DIAGNOSTIC_END"

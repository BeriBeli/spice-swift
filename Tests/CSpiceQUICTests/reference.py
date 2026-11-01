"""Build an independent pinned C oracle for the spice-gtk QUIC artifact.

Only platform macro headers are supplied here. The codec, templates, public
header and model table are read unchanged from the verified upstream archive.
"""
import hashlib
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / '.build/quic-reference'
REVISION = '71e45706981973014eaab3d4b533d35d79e19ffa'
SHA256 = 'f5cf6afab9a224fc34ff7cd578897a5769ac80aeeff54ddc937506de4628d69e'
NAME = f'spice-common-{REVISION}.tar.gz'
URL = f'https://gitlab.freedesktop.org/spice/spice-common/-/archive/{REVISION}/{NAME}'


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    archive = WORK / NAME
    if not archive.exists():
        temporary = WORK / (NAME + '.download')
        subprocess.run(['curl', '-fL', '--retry', '3', '-o', str(temporary), URL], check=True)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != SHA256:
            temporary.unlink()
            raise RuntimeError('spice-common archive checksum mismatch')
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('spice-common archive checksum mismatch')
    source = WORK / 'src'
    (source / 'spice').mkdir(parents=True, exist_ok=True)
    # Read specific regular files rather than extracting archive paths/symlinks.
    with tarfile.open(archive) as tar:
        for name in ['quic.c', 'quic_tmpl.c', 'quic_family_tmpl.c', 'quic.h',
                     'quic_config.h', 'macros.h', 'verify.h']:
            member = tar.getmember(f'spice-common-{REVISION}/common/{name}')
            if not member.isfile():
                raise RuntimeError('unexpected archive member type')
            (source/name).write_bytes(tar.extractfile(member).read())
    (source/'spice/macros.h').write_text('''#pragma once
#include <stdint.h>
#define SPICE_BEGIN_DECLS
#define SPICE_END_DECLS
#define SPICE_GNUC_NORETURN __attribute__((noreturn))
#define SPICE_GNUC_PRINTF(a,b) __attribute__((format(printf,a,b)))
#define SPICE_ATTR_PACKED __attribute__((packed))
#define SPICE_GNUC_UNUSED __attribute__((unused))
''')
    (source/'spice/types.h').write_text('#include <stdint.h>\n#include <stddef.h>\n')
    (source/'spice/start-packed.h').write_text('#pragma pack(push, 1)\n')
    (source/'spice/end-packed.h').write_text('#pragma pack(pop)\n')
    (source/'config.h').write_text('#define ENABLE_EXTRA_CHECKS 1\n')
    (source/'log.h').write_text('''#pragma once
#include <assert.h>
#define spice_assert(v) assert(v)
#define spice_extra_assert(v) assert(v)
#define spice_return_if_fail(v) do { if (!(v)) return; } while (0)
#define spice_warn_if_reached() ((void)0)
#define ABS(v) ((v) < 0 ? -(v) : (v))
#define G_UNLIKELY(v) __builtin_expect(!!(v),0)
#define GUINT32_TO_LE(v) (v)
#define GUINT32_FROM_LE(v) (v)
#define TRUE 1
#define FALSE 0
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error This validation macro adapter requires a little-endian host
#endif
''')
    return source


def object_file(sanitize=False):
    source = prepare()
    output = WORK / ('quic' + ('-asan' if sanitize else '') + '.o')
    command = ['xcrun', 'clang', '-c', str(source/'quic.c'), '-I', str(source),
               '-std=c11', '-O2', '-g', '-mmacosx-version-min=26.0', '-o', str(output)]
    if sanitize:
        command += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    subprocess.run(command, check=True)
    return output

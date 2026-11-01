#!/usr/bin/env python3
"""Link one upstream-header C consumer to the oracle and shipped spice-gtk codec."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import reference

ROOT = Path(__file__).resolve().parents[2]
BASE = Path(__file__).resolve().parent
WORK = ROOT / '.build/quic-validation'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    WORK.mkdir(parents=True, exist_ok=True)
    source = reference.prepare()
    oracle = reference.object_file(args.sanitize)
    flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if args.sanitize else []
    consumer = WORK / 'consumer.o'
    subprocess.run([
        'xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
        '-O1', '-g', '-mmacosx-version-min=26.0', '-I', str(source),
        '-c', str(BASE / 'abi_consumer.c'), '-o', str(consumer), *flags,
    ], check=True)
    artifact = ROOT / 'Artifacts/CSpiceQUIC.xcframework'
    product = artifact / 'macos-arm64/CSpiceQUIC.framework/Versions/A/CSpiceQUIC'
    provenance = (artifact / 'BUILD_PROVENANCE.txt').read_text()
    for line in provenance.splitlines():
        if line.startswith('Upstream source SHA-256: '):
            digest, name = line.removeprefix('Upstream source SHA-256: ').split(' ', 1)
            if hashlib.sha256((source / Path(name).name).read_bytes()).hexdigest() != digest:
                raise RuntimeError('oracle and spice-gtk codec source differ: ' + name)
    for backend, library in [('oracle', oracle), ('spice-gtk', product)]:
        executable = WORK / ('consumer-' + backend)
        subprocess.run([
            'xcrun', 'clang', str(consumer), str(library),
            '-o', str(executable), *flags,
        ], check=True)
        subprocess.run([str(executable), str(WORK / (backend + '.bin'))], check=True, env={
            **os.environ,
            'UBSAN_OPTIONS': 'halt_on_error=1:print_stacktrace=1',
            'ASAN_OPTIONS': 'halt_on_error=1:detect_stack_use_after_return=1',
        })
    expected = (WORK / 'oracle.bin').read_bytes()
    if expected != (WORK / 'spice-gtk.bin').read_bytes():
        raise RuntimeError('spice-gtk and independent C produced different encoded/decoded bytes')
    report = {
        'backend': 'spice-gtk 0.42 / spice-common C',
        'identicalConsumerBytes': len(expected),
        'consumerOutputSHA256': hashlib.sha256(expected).hexdigest(),
        'oracleRevision': reference.REVISION,
        'consumerSHA256': hashlib.sha256((BASE / 'abi_consumer.c').read_bytes()).hexdigest(),
        'consumerAndOracleSanitized': args.sanitize,
        'artifactSanitized': False,
        'artifactSHA256': hashlib.sha256(product.read_bytes()).hexdigest(),
        'provenance': provenance,
        'scope': 'Same upstream-header C consumer; pixel/guard, allocation, callback, longjmp and context reuse checks.',
    }
    (WORK / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()

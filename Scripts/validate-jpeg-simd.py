#!/usr/bin/env python3
"""Compare the shipped JPEG archive to a fresh scalar build of its pinned source.

Pass the source archive cached by build-native-dependencies.sh. No live peer or
installed app is used. --asan instruments fresh scalar AND Neon builds rather
than pretending that linking the release archive instruments native internals.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FRAMEWORK = ROOT / 'Artifacts/CTurboJPEG.xcframework'
ARCHIVE = FRAMEWORK / 'macos-arm64/CTurboJPEG.framework/Versions/A/CTurboJPEG'


def run(args, **kwargs):
    return subprocess.check_output([str(a) for a in args], text=True, timeout=300, **kwargs).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_archive', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--asan', action='store_true')
    args = parser.parse_args()
    provenance = dict(line.split(': ', 1) for line in
                      (FRAMEWORK / 'BUILD_PROVENANCE.txt').read_text().splitlines() if ': ' in line)
    if digest(args.source_archive) != provenance['SHA-256']:
        raise SystemExit('source archive checksum mismatch')
    if digest(ARCHIVE) != provenance['Archive SHA-256']:
        raise SystemExit('shipped archive checksum mismatch')
    env = dict(os.environ)
    for key in list(env):
        if key in ('CFLAGS', 'CPPFLAGS', 'CXXFLAGS', 'LDFLAGS') or key.startswith('JSIMD_'):
            del env[key]
    compiler = run(['xcrun', '--sdk', 'macosx', '--find', 'clang'])
    sdk = run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    sanitizer = ['-fsanitize=address', '-fno-omit-frame-pointer'] if args.asan else []
    report = {'asan': args.asan, 'archive_sha256': digest(ARCHIVE),
              'source_sha256': digest(args.source_archive),
              'compiler': run([compiler, '--version']).splitlines()[0],
              'hardware': run(['sysctl', '-n', 'machdep.cpu.brand_string']),
              'os': run(['sw_vers', '-productVersion']), 'cases': []}
    with tempfile.TemporaryDirectory(prefix='swiftspice-jpeg-') as directory:
        work = Path(directory)
        run(['tar', '-xf', args.source_archive.resolve(), '-C', work])
        source, = work.glob('libjpeg-turbo-*')
        version = source.name.removeprefix('libjpeg-turbo-')
        executables = {}
        for name in ('scalar', 'neon'):
            library = ARCHIVE
            if name == 'scalar' or args.asan:
                build = work / name
                flags = ['cmake', '-S', source, '-B', build,
                         f'-DCMAKE_C_COMPILER={compiler}', '-DCMAKE_BUILD_TYPE=Release',
                         f'-DBUILD={version}', '-DCMAKE_OSX_ARCHITECTURES=arm64',
                         '-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0', f'-DCMAKE_OSX_SYSROOT={sdk}',
                         '-DENABLE_SHARED=OFF', '-DWITH_JAVA=OFF', '-DWITH_TESTS=OFF',
                         '-DWITH_TOOLS=OFF', f'-DWITH_SIMD={"ON" if name == "neon" else "OFF"}']
                if name == 'neon':
                    flags += ['-DREQUIRE_SIMD=ON']
                if sanitizer:
                    flags += [f'-DCMAKE_C_FLAGS={" ".join(sanitizer)}']
                run(flags, env=env)
                run(['cmake', '--build', build, '--target', 'turbojpeg-static', '--parallel'], env=env)
                library = build / 'libturbojpeg.a'
            executable = work / f'check-{name}'
            run([compiler, '-O3', '-std=c17', '-Wall', '-Wextra', '-Werror',
                 '-arch', 'arm64', '-mmacosx-version-min=26.0', '-isysroot', sdk,
                 *sanitizer, '-I', source / 'src', ROOT / 'Benchmarks/NativeJPEG/jpeg-check.c',
                 library, '-o', executable], env=env)
            executables[name] = executable
        # Small/odd dimensions exercise vector tails and padded rows. Large
        # fixtures exercise the default MJPEG load, with no skipped frames.
        for width, height in ((1, 1), (9, 7), (65, 33), (1920, 1080), (3840, 2160)):
            for subsamp in (0, 1, 2, 3):  # 4:4:4, 4:2:2, 4:2:0, grayscale
                progressive = int(width == 65)
                jpeg = work / 'input.jpg'
                run([executables['neon'], 'generate', jpeg, width, height, subsamp, 80, progressive], env=env)
                timed = width >= 1920 and subsamp in (0, 2) and not args.asan
                rounds, iterations = (5, 30) if timed else (1, 1)
                samples = {'scalar': [], 'neon': []}
                expected = None
                for trial in range(rounds):
                    # Alternate order to reduce warm/thermal order bias.
                    for name in (('scalar', 'neon') if trial % 2 == 0 else ('neon', 'scalar')):
                        output = work / f'{name}.bgra'
                        result = json.loads(run([executables[name], 'decode', jpeg, output, iterations], env=env))
                        actual = output.read_bytes()
                        if expected is None:
                            expected = actual
                        if actual != expected:
                            raise SystemExit(f'pixel mismatch: {width}x{height}, subsamp={subsamp}, {name}')
                        samples[name].append(result)
                report['cases'].append({'width': width, 'height': height, 'subsampling': subsamp,
                                        'progressive': bool(progressive), 'jpeg_sha256': digest(jpeg),
                                        'bgra_sha256': hashlib.sha256(expected).hexdigest(),
                                        'bit_exact': True, 'samples': samples})
                if timed:
                    print(f'{width}x{height} subsamp={subsamp}: ' + ', '.join(
                        f'{name} {statistics.median(s["cpu_ms_per_frame"] for s in samples[name]):.3f} CPU ms/frame'
                        for name in samples), flush=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: {len(report["cases"])} exact scalar/Neon comparisons, guards, padding and alpha; {args.output}')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Offline, source-only OpenSSL 3.5.7 build recipe for isolated native tests.

No downloader, package manager, sudo, signing, app integration or network call.
The input source must already be approved and independently verified by its owner.
The supplied tree hash prevents later drift; it does not authenticate a publisher.
"""

import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


VERSION = "3.5.7"
MODULE_MAP = '''module OpenSSLCrypto [system] {
    umbrella "openssl"
    export *
    module * { export * }
}
'''


def source_manifest(source):
    """Hash every regular file except root .git metadata; reject symlinks."""
    entries = []
    for base, directories, files in os.walk(source, followlinks=False):
        base = pathlib.Path(base)
        if base == source:
            directories[:] = [name for name in directories if name != ".git"]
            files = [name for name in files if name != ".git"]
        for name in directories + files:
            path = base / name
            if path.is_symlink():
                raise ValueError("Source contains a symlink: " + str(path.relative_to(source)))
        for name in files:
            path = base / name
            if not path.is_file():
                raise ValueError("Source contains a non-regular file: " + str(path))
            relative = path.relative_to(source).as_posix()
            if any(char in relative for char in "\r\n\0"):
                raise ValueError("Unsupported source filename")
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            entries.append({"path": relative, "sha256": digest.hexdigest()})
    entries.sort(key=lambda item: item["path"])
    tree = hashlib.sha256()
    for entry in entries:
        tree.update((entry["path"] + "\0" + entry["sha256"] + "\n").encode("utf-8"))
    return tree.hexdigest(), entries


def run(command, *, cwd=None, env=None, log=None):
    print("+ " + shlex.join([str(value) for value in command]), flush=True)
    if log is None:
        subprocess.run(command, cwd=cwd, env=env, check=True)
    else:
        with log.open("a") as stream:
            stream.write("+ " + shlex.join([str(value) for value in command]) + "\n")
            stream.flush()
            subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)


def output(command):
    return subprocess.check_output(command, text=True).strip()


def preserve_notices(source, destination):
    destination.mkdir()
    # Keep all shipped attribution/copyright notices, including nested licenses.
    for base, directories, files in os.walk(source):
        if pathlib.Path(base) == source:
            directories[:] = [name for name in directories if name != ".git"]
        for name in files:
            if re.match(r"^(LICENSE|NOTICE|COPYING|AUTHORS|COPYRIGHT)(\.|$)", name, re.I):
                path = pathlib.Path(base) / name
                target = destination / path.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)


def merge_simulator_headers(arm64, x86_64, destination):
    """Preserve arch-dependent generated config rather than picking one slice."""
    arm_files = {p.relative_to(arm64) for p in arm64.rglob("*") if p.is_file()}
    x86_files = {p.relative_to(x86_64) for p in x86_64.rglob("*") if p.is_file()}
    if arm_files != x86_files:
        raise ValueError("Simulator header sets differ; manual review required")
    shutil.copytree(arm64, destination)
    for relative in sorted(arm_files):
        a = (arm64 / relative).read_bytes()
        b = (x86_64 / relative).read_bytes()
        if a == b:
            continue
        if relative.as_posix() not in ("openssl/configuration.h", "openssl/opensslconf.h"):
            raise ValueError("Unexpected architecture-dependent header: " + str(relative))
        for arch, data in (("arm64", a), ("x86_64", b)):
            target = destination / "openssl" / "leap-arch" / arch / relative.name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (destination / relative).write_text(
            "/* Generated architecture selector; upstream headers are preserved. */\n"
            "#if defined(__arm64__) || defined(__aarch64__)\n"
            '# include "leap-arch/arm64/' + relative.name + '"\n'
            "#elif defined(__x86_64__)\n"
            '# include "leap-arch/x86_64/' + relative.name + '"\n'
            "#else\n#error Unsupported simulator architecture\n#endif\n"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path, required=True, help="Existing pristine, approved OpenSSL 3.5.7 source directory")
    parser.add_argument("--print-source-sha256", action="store_true", help="Read/hash only; works without Xcode and does not execute source")
    parser.add_argument("--source-sha256", help="Previously approved tree SHA-256 (not an archive digest)")
    parser.add_argument("--mode", choices=("macos", "ios"))
    parser.add_argument("--output", type=pathlib.Path, help="New output directory; existing paths are never overwritten")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    if not source.is_dir():
        raise ValueError("--source must be a directory")
    for name in ("Configure", "VERSION.dat", "LICENSE.txt", "Configurations/15-ios.conf"):
        if not (source / name).is_file():
            raise ValueError("Required OpenSSL source file missing: " + name)
    if any((source / name).exists() for name in ("Makefile", "configdata.pm")):
        raise ValueError("Source is already configured; supply a separate pristine source tree")
    version_text = (source / "VERSION.dat").read_text()
    version_fields = dict(re.findall(r"^(MAJOR|MINOR|PATCH)=(\d+)\s*$", version_text, re.M))
    actual_version = ".".join(version_fields.get(key, "?") for key in ("MAJOR", "MINOR", "PATCH"))
    if actual_version != VERSION:
        raise ValueError("This reviewed recipe requires OpenSSL " + VERSION + "; found " + actual_version)
    for key in ("PRE_RELEASE_TAG", "BUILD_METADATA"):
        match = re.search(r"^" + key + r"=([^\r\n]*)$", version_text, re.M)
        if match and match.group(1).strip():
            raise ValueError("Expected the unmodified release version; " + key + " is nonempty")
    digest, entries = source_manifest(source)
    if args.print_source_sha256:
        print(digest)
        return
    if not args.mode or not args.output or not args.source_sha256:
        parser.error("Builds require --mode, --output and --source-sha256")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", args.source_sha256):
        raise ValueError("--source-sha256 must contain exactly 64 hexadecimal characters")
    if digest != args.source_sha256.lower():
        raise ValueError("Source tree SHA-256 mismatch; nothing was executed or built")
    if args.jobs < 1 or args.jobs > 128:
        raise ValueError("--jobs must be between 1 and 128")
    if platform.system() != "Darwin":
        raise ValueError("Build NOT RUN: macOS with full Xcode and required SDKs is required")
    for name in ("xcrun", "xcodebuild", "perl", "make"):
        if shutil.which(name) is None:
            raise ValueError("Build prerequisite unavailable: " + name)
    destination = args.output.resolve()
    if destination == source or source in destination.parents or destination in source.parents:
        raise ValueError("Source and output must be separate, non-overlapping directories")
    if destination.exists():
        raise ValueError("Output already exists; choose a new directory (no automatic deletion)")
    sdk_names = ("macosx",) if args.mode == "macos" else ("iphoneos", "iphonesimulator")
    sdk_paths = {sdk: output(["xcrun", "--sdk", sdk, "--show-sdk-path"]) for sdk in sdk_names}
    xcode_version = output(["xcodebuild", "-version"])
    host_arch = platform.machine()
    if args.mode == "macos" and host_arch not in ("arm64", "x86_64"):
        raise ValueError("Unsupported macOS host architecture: " + host_arch)
    configs = [
        ("macos-" + host_arch, "darwin64-" + host_arch + "-cc", "macosx", host_arch, "-mmacosx-version-min=13.0")
    ] if args.mode == "macos" else [
        ("ios-arm64", "ios64-xcrun", "iphoneos", "arm64", "-miphoneos-version-min=17.0"),
        ("sim-arm64", "iossimulator-arm64-xcrun", "iphonesimulator", "arm64", "-mios-simulator-version-min=17.0"),
        ("sim-x86_64", "iossimulator-x86_64-xcrun", "iphonesimulator", "x86_64", "-mios-simulator-version-min=17.0"),
    ]
    flags = ["no-shared", "no-module", "no-dso", "no-tests", "no-apps", "no-autoload-config", "--libdir=lib"]
    environment = os.environ.copy()
    for key in ("CC", "CXX", "CFLAGS", "CPPFLAGS", "CXXFLAGS", "LDFLAGS", "SDKROOT", "CROSS_COMPILE", "CROSS_TOP", "CROSS_SDK",
                "AR", "ARFLAGS", "AS", "ASFLAGS", "CPP", "CPPDEFINES", "CPPINCLUDES", "RANLIB", "RC", "RCFLAGS",
                "DESTDIR", "INSTALL_PREFIX", "MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS", "MAKEOVERRIDES",
                "PERL5LIB", "PERL5OPT", "PERLLIB", "MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET"):
        environment.pop(key, None)
    for key in list(environment):
        if key.startswith("OPENSSL_"):
            environment.pop(key)
    destination.mkdir(parents=True)
    (destination / "SOURCE-MANIFEST.json").write_text(json.dumps({"tree_sha256": digest, "files": entries}, indent=2) + "\n")
    preserve_notices(source, destination / "Notices")
    metadata = {"openssl_version": VERSION, "source_tree_sha256": digest, "xcode": xcode_version,
                "sdks": sdk_paths, "mode": args.mode, "targets": configs, "flags": flags,
                "status": "building", "tests": "Not run; this script builds source libraries only."}
    manifest_path = destination / "BUILD-MANIFEST.json"
    manifest_path.write_text(json.dumps(metadata, indent=2) + "\n")
    try:
        with tempfile.TemporaryDirectory(prefix="leap-native-openssl-") as temporary:
            work_root = pathlib.Path(temporary)
            for name, target, sdk, arch, minimum in configs:
                work = work_root / name
                shutil.copytree(source, work, ignore=lambda root, names: [".git"] if pathlib.Path(root) == source and ".git" in names else [])
                prefix = destination if args.mode == "macos" else destination / name
                log = destination / (name + ".log")
                configure = ["perl", "Configure", target, *flags, "--prefix=" + str(prefix), minimum]
                if sdk == "macosx":
                    configure.append("CC=xcrun -sdk macosx clang")
                run(configure, cwd=work, env=environment, log=log)
                run(["make", "-j" + str(args.jobs), "build_libs"], cwd=work, env=environment, log=log)
                # Copies development outputs into this explicit local prefix only.
                run(["make", "install_dev"], cwd=work, env=environment, log=log)
                library = prefix / "lib" / "libcrypto.a"
                if not library.is_file() or not (prefix / "include/openssl/opensslv.h").is_file():
                    raise ValueError("Expected static library/headers missing for " + name)
                run(["xcrun", "lipo", str(library), "-verify_arch", arch], log=log)
                (prefix / "include/module.modulemap").write_text(MODULE_MAP)
            if args.mode == "ios":
                universal = destination / "ios-simulator"
                universal.mkdir()
                merge_simulator_headers(destination / "sim-arm64/include", destination / "sim-x86_64/include", universal / "include")
                run(["xcrun", "lipo", "-create", str(destination / "sim-arm64/lib/libcrypto.a"),
                     str(destination / "sim-x86_64/lib/libcrypto.a"), "-output", str(universal / "libcrypto.a")])
                run(["xcrun", "lipo", str(universal / "libcrypto.a"), "-verify_arch", "arm64", "x86_64"])
                framework = destination / "OpenSSLCrypto.xcframework"
                run(["xcodebuild", "-create-xcframework", "-library", str(destination / "ios-arm64/lib/libcrypto.a"),
                     "-headers", str(destination / "ios-arm64/include"), "-library", str(universal / "libcrypto.a"),
                     "-headers", str(universal / "include"), "-output", str(framework)])
                shutil.copytree(destination / "Notices", framework / "Notices")
        final_digest, _ = source_manifest(source)
        if final_digest != digest:
            raise ValueError("Input source changed during the build; do not use the result")
        metadata["status"] = "built; native harness, Swift, simulator and device tests still required"
        manifest_path.write_text(json.dumps(metadata, indent=2) + "\n")
        _, hashes = source_manifest(destination)
        (destination / "OUTPUT-SHA256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    except Exception:
        metadata["status"] = "failed; partial output must not be used"
        manifest_path.write_text(json.dumps(metadata, indent=2) + "\n")
        raise
    print("Source build completed at " + str(destination))
    print("This is unsigned build output, not evidence of Swift/iOS/device tests or release approval.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(2)

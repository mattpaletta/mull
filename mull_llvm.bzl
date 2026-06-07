load("//:bazel/os_detection.bzl", "is_macos", "is_redhat")

# Build file used when LLVM is found locally. Mirrors the layout produced by
# `mull_deps.bzl` so consumers see the same targets regardless of how LLVM is
# provided.
_LOCAL_BUILD_FILE = """\
load("@bazel_skylib//rules:native_binary.bzl", "native_binary")
load("@rules_cc//cc:defs.bzl", "cc_import", "cc_library")

package(default_visibility = ["//visibility:public"])

cc_import(
    name = "llvm_private",
    hdrs = glob([
        "include/llvm/**/*.h",
        "include/llvm-c/**/*.h",
        "include/llvm/**/*.def",
        "include/llvm/**/*.inc",
    ], allow_empty = True),
    shared_library = "{LIBDIR}/{LIBLLVM_DYLIB}",
)

cc_library(
    name = "libllvm",
    includes = ["include"],
    deps = [":llvm_private"],
)

cc_import(
    name = "libclang_private",
    hdrs = glob([
        "include/clang/**/*.h",
        "include/clang-c/**/*.h",
        "include/clang/**/*.def",
        "include/clang/**/*.inc",
    ], allow_empty = True),
    shared_library = "{LIBDIR}/{LIBCLANG_CPP_DYLIB}",
)

cc_library(
    name = "libclang",
    includes = ["include"],
    deps = [":libclang_private"],
)

native_binary(
    name = "clang",
    src = "bin/clang",
    out = "clang",
)

native_binary(
    name = "clangxx",
    src = "bin/clang++",
    out = "clangxx",
)

native_binary(
    name = "llvm-profdata",
    src = "bin/llvm-profdata",
    out = "llvm-profdata",
)
"""

# Build file used when LLVM is not installed locally. Aliases to
# `@llvm-project//...`, which is populated by the integrator's
# llvm_configure() (either via `@mull//:mull_llvm_source.bzl` or their own
# extension; see mono/runtime for examples).
_SOURCE_BUILD_FILE = """\
package(default_visibility = ["//visibility:public"])

alias(name = "libllvm",  actual = "@llvm-project//llvm:Core")
alias(name = "libclang", actual = "@llvm-project//clang:clang")
alias(name = "clang",    actual = "@llvm-project//clang:clang")
alias(name = "clangxx",  actual = "@llvm-project//clang:clang")
alias(name = "llvm-profdata", actual = "@llvm-project//llvm:llvm-profdata")
"""

_INFO_BZL = """\
LLVM_VERSION = "{version}"
LLVM_FROM_SOURCE = {from_source}
LLVM_LOCAL_PATH = "{local_path}"
"""

def _llvm_install_root(repository_ctx, version):
    if is_macos(repository_ctx):
        return "/opt/homebrew/opt/llvm@" + version
    if is_redhat(repository_ctx):
        return "/usr"
    return "/usr/lib/llvm-" + version

def _is_installed(repository_ctx, version):
    if is_redhat(repository_ctx):
        return repository_ctx.path("/usr/bin/llvm-config-%s" % version).exists
    return repository_ctx.path(_llvm_install_root(repository_ctx, version)).exists

def _dylib_ext(repository_ctx):
    return "dylib" if is_macos(repository_ctx) else "so"

def _find_dylib(repository_ctx, libdir, lib, version):
    plain = "lib" + lib + "." + _dylib_ext(repository_ctx)
    versioned = "lib" + lib + "-" + version + "." + _dylib_ext(repository_ctx)
    for f in repository_ctx.path(libdir).readdir():
        if f.basename.startswith(plain):
            return f.basename
        if f.basename.startswith(versioned):
            return f.basename
    return None

def _local_llvm_repo_impl(repository_ctx):
    version = repository_ctx.attr.version
    if is_redhat(repository_ctx):
        path = "/usr"
        libdir = "lib64"
    elif is_macos(repository_ctx):
        path = "/opt/homebrew/opt/llvm@" + version
        libdir = "lib"
    else:
        path = "/usr/lib/llvm-" + version
        libdir = "lib"
    llvm_dylib = _find_dylib(repository_ctx, path + "/" + libdir, "LLVM", version)
    clang_dylib = _find_dylib(repository_ctx, path + "/" + libdir, "clang-cpp", version)
    if llvm_dylib == None or clang_dylib == None:
        fail("mull_llvm: could not locate libLLVM/libclang-cpp shared libraries for version %s under %s/%s" % (version, path, libdir))

    # Symlink the discovered install into the repo so the relative paths in
    # the build file resolve regardless of where the system put LLVM.
    for entry in ["bin", "include", libdir]:
        src = repository_ctx.path(path + "/" + entry)
        if src.exists:
            repository_ctx.symlink(src, entry)

    repository_ctx.file(
        "BUILD",
        content = _LOCAL_BUILD_FILE.format(
            LIBLLVM_DYLIB = llvm_dylib,
            LIBCLANG_CPP_DYLIB = clang_dylib,
            LIBDIR = libdir,
        ),
    )
    repository_ctx.file(
        "info.bzl",
        content = _INFO_BZL.format(
            version = version,
            from_source = "False",
            local_path = path,
        ),
    )

local_llvm_repo = repository_rule(
    implementation = _local_llvm_repo_impl,
    local = True,
    attrs = {
        "version": attr.string(mandatory = True),
    },
)

def _source_llvm_repo_impl(repository_ctx):
    repository_ctx.file("BUILD", content = _SOURCE_BUILD_FILE)
    repository_ctx.file(
        "info.bzl",
        content = _INFO_BZL.format(
            version = repository_ctx.attr.version,
            from_source = "True",
            local_path = "",
        ),
    )

source_llvm_repo = repository_rule(
    implementation = _source_llvm_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
    },
)

def _mull_llvm_impl(module_ctx):
    version = None
    for mod in module_ctx.modules:
        for tag in mod.tags.configure:
            if version != None and version != tag.version:
                fail("mull_llvm.configure(version=...) called with conflicting values: %s vs %s" % (version, tag.version))
            version = tag.version
    if version == None:
        fail("mull_llvm requires exactly one configure(version=...) call")

    if _is_installed(module_ctx, version):
        local_llvm_repo(name = "mull_llvm", version = version)
    else:
        source_llvm_repo(name = "mull_llvm", version = version)

mull_llvm = module_extension(
    implementation = _mull_llvm_impl,
    tag_classes = {
        "configure": tag_class(attrs = {
            "version": attr.string(
                mandatory = True,
                doc = "Major LLVM version to use (e.g. \"19\", \"20\", \"21\"). If installed locally, the system install is used. Otherwise mull falls back to aliasing @llvm-project (which the integrator must materialize from source via llvm_configure; see mull_llvm_source.bzl or mono/runtime as examples).",
            ),
        }),
    },
)

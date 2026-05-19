# buildifier: disable=module-docstring
#
# Helper module extension that runs `llvm_configure` so integrators don't have
# to copy the loader incantation. Use this only if you want mull to fall back
# to a source build of LLVM when the requested version isn't installed
# locally.
#
# This file loads `@llvm-raw//utils/bazel:configure.bzl`, so the integrator
# must declare the `@llvm-raw`, `@llvm_zlib`, and `@llvm_zstd` http_archives
# in their MODULE.bazel *before* using this extension. See mono/runtime for
# concrete examples.
load("@llvm-raw//utils/bazel:configure.bzl", "llvm_configure")

def _mull_llvm_source_impl(module_ctx):
    targets = ["AArch64", "X86"]
    for mod in module_ctx.modules:
        for tag in mod.tags.configure:
            if tag.targets:
                targets = tag.targets
    llvm_configure(name = "llvm-project", targets = targets)

mull_llvm_source = module_extension(
    implementation = _mull_llvm_source_impl,
    tag_classes = {
        "configure": tag_class(attrs = {
            "targets": attr.string_list(
                default = [],
                doc = "LLVM target architectures to enable in the source build. Defaults to [\"AArch64\", \"X86\"].",
            ),
        }),
    },
)

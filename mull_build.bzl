# buildifier: disable=module-docstring
load("@available_llvm_versions//:mull_llvm_versions.bzl", "AVAILABLE_LLVM_VERSIONS", "HERMETIC_LLVM")
load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library")

def mull_build(name):
    for llvm_version in AVAILABLE_LLVM_VERSIONS:
        cc_library(
            name = "libmull_%s" % llvm_version,
            srcs = native.glob(["lib/**/*.cpp"]),
            hdrs = native.glob(["include/**/*.h"]),
            includes = ["include"],
            # LLVM is built with -fno-rtti; match it so we don't emit RTTI
            # references (e.g. typeinfo for llvm::CallbackVH) that the LLVM
            # shared library does not provide. Mull itself uses no C++ RTTI.
            copts = ["-fno-rtti"],
            deps = [
                "@mull_irm_%s//:irm" % llvm_version,
                "@llvm_%s//:libclang" % llvm_version,
                "@llvm_%s//:libllvm" % llvm_version,
                "@sqlite3",
                "//rust/mull-cxx-bridge",
                "//rust/mull-cxx-bridge:bridge",
            ],
        )

        cc_binary(
            name = "mull-cxx-ir-frontend-%s" % llvm_version,
            srcs = native.glob(["tools/mull-ir-frontend/*.cpp"]),
            linkshared = True,
            copts = ["-fno-rtti"],
            # rpath $ORIGIN lets the plugin resolve its shared library deps
            # (libclang-cpp.so) from its own directory when a downstream clang
            # dlopen's it via -fpass-plugin. See the co-located genrule below.
            linkopts = ["-Wl,-rpath,$$ORIGIN"],
            deps = [
                ":libmull_%s" % llvm_version,
                "@llvm_%s//:libclang" % llvm_version,
            ],
            tags = ["llvm_%s" % llvm_version],
            # Public so downstream projects can pass the plugin to clang via
            # -fpass-plugin when integrating Mull mutation testing in Bazel.
            visibility = ["//visibility:public"],
        )

        native.genrule(
            name = "mull-ir-frontend-%s-gen" % llvm_version,
            srcs = [":mull-cxx-ir-frontend-%s" % llvm_version],
            outs = ["mull-ir-frontend-%s" % llvm_version],
            cmd = "cp $(SRCS) $(OUTS)",
            # Public so the generated plugin file can be consumed downstream.
            visibility = ["//visibility:public"],
        )

        # For a hermetic LLVM, the plugin's libclang-cpp.so isn't on any system
        # path, so copy it next to the generated plugin. Combined with the
        # plugin's rpath $ORIGIN, a downstream clang can load the plugin by
        # staging both files (e.g. via additional_compiler_inputs) in the same
        # directory.
        if llvm_version in HERMETIC_LLVM:
            native.genrule(
                name = "mull-ir-frontend-%s-libclang" % llvm_version,
                srcs = ["@llvm_%s//:libclang_cpp_shared" % llvm_version],
                outs = [HERMETIC_LLVM[llvm_version]["clang_dylib"]],
                cmd = "cp -L $(SRCS) $(OUTS)",
                visibility = ["//visibility:public"],
            )

        cc_binary(
            name = "mull-cxx-ast-frontend-%s" % llvm_version,
            srcs = native.glob([
                "tools/mull-cxx-frontend/src/*.cpp",
                "tools/mull-cxx-frontend/src/*.h",
            ]),
            linkshared = True,
            copts = ["-fno-rtti"],
            deps = [
                ":libmull_%s" % llvm_version,
                "@llvm_%s//:libclang" % llvm_version,
            ],
            tags = ["llvm_%s" % llvm_version],
        )

        native.genrule(
            name = "mull-ast-frontend-%s-gen" % llvm_version,
            srcs = [":mull-cxx-ast-frontend-%s" % llvm_version],
            outs = ["mull-ast-frontend-%s" % llvm_version],
            cmd = "cp $(SRCS) $(OUTS)",
        )

        cc_binary(
            name = "mull-instrument-%s" % llvm_version,
            srcs = ["tools/mull-instrument/mull-instrument.cpp"],
            copts = ["-fno-rtti"],
            deps = [
                ":libmull_%s" % llvm_version,
                "@llvm_%s//:libllvm" % llvm_version,
            ],
            tags = ["llvm_%s" % llvm_version],
        )

    # Documentation tool - uses single LLVM version only
    latest_llvm = AVAILABLE_LLVM_VERSIONS[0]
    cc_binary(
        name = "mull-dump-mutators",
        srcs = ["tools/mull-dump-mutators/mull-dump-mutators.cpp"],
        copts = ["-fno-rtti"],
        deps = [
            ":libmull_%s" % latest_llvm,
        ],
    )

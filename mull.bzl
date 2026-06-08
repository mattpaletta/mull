"""Standalone Mull mutation testing for Bazel cc targets (no clang plugin).

Mull normally embeds mutants via a clang pass-plugin (`-fpass-plugin`). That
loads Mull's `libclang-cpp.so` into the toolchain's clang, but a hermetic LLVM
release ships a *statically* linked clang, so the plugin's LLVM and clang's own
LLVM become two runtimes in one process and clang double-frees a managed-static
at exit. Mull ships the standalone `mull-instrument` tool for exactly this case
("environments where LLVM pass plugins don't work (static LLVM builds without
shared libraries)").

`mull_instrumented_binary` mirrors Mull's own standalone integration test:

    clang++ -O0 -c -emit-llvm -g -grecord-command-line t.cpp -o t.bc
    mull-instrument t.bc -o t-mutated.bc      # its own process: one LLVM
    clang++ -c t-mutated.bc -o t.o
    clang++ t.o <test deps>... -o binary       # ordinary link, mutants embedded
    mull-runner binary                         # via mull_runner_test, below

`mull-instrument` runs as a separate process (no plugin is loaded into clang),
and the mutation runtime is embedded directly in the bitcode, so the final link
is an ordinary toolchain link. The sources, the test framework and the library
under test are all built and linked by the single Bazel C++ toolchain, so there
is no std:: ABI mismatch and no duplicated LLVM.

Usage (see docs/BazelMutationTesting.rst for the full guide)::

    load("@mull//:mull.bzl", "mull_instrumented_binary", "mull_runner_test")

    mull_instrumented_binary(
        name = "mutation_test_bin",
        testonly = True,
        srcs = glob(["*.test.cpp"]),
        copts = ["-std=c++20"],
        mull_config = "mull.yml",
        tags = ["manual"],
        deps = [":lib", "@googletest//:gtest", "@googletest//:gtest_main"],
    )

    mull_runner_test(
        name = "mutation_test",
        timeout = "eternal",
        instrumented_binary = ":mutation_test_bin",
        mull_config = "mull.yml",
        tags = ["manual"],
    )

`mull_instrument`/`mull_runner` default to Mull's LLVM 21 tools; override them
to target a different hermetic LLVM (e.g. `@mull//:mull-instrument-20`).
"""

load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "ACTION_NAMES")
# rules_cc's Starlark cc API is loaded explicitly rather than via globals so the
# rule keeps working under --incompatible_autoload_externally in consumers.
load("@rules_cc//cc:defs.bzl", "CcInfo", "cc_common")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")

def _mull_instrumented_binary_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    compilation_contexts = [dep[CcInfo].compilation_context for dep in ctx.attr.deps]
    linking_contexts = [
        dep[CcInfo].linking_context
        for dep in ctx.attr.deps
        if dep[CcInfo].linking_context != None
    ]

    # 1. Compile each source to LLVM bitcode. With -emit-llvm the "object" files
    #    clang writes contain bitcode, which is what mull-instrument consumes.
    #    -O0 keeps mutants from being optimized away; -g/-grecord-command-line
    #    give Mull the debug info it needs to map mutants back to source.
    _, compilation_outputs = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        name = ctx.label.name + "_bitcode",
        srcs = ctx.files.srcs,
        compilation_contexts = compilation_contexts,
        user_compile_flags = ctx.attr.copts + [
            "-O0",
            "-g",
            "-grecord-command-line",
            "-emit-llvm",
        ] + ctx.attr.sanitize_bounds_copts,
    )

    use_pic = bool(compilation_outputs.pic_objects)
    bitcode_objects = compilation_outputs.pic_objects if use_pic else compilation_outputs.objects

    # The bitcode -> native object recompile reuses the toolchain's compiler so
    # it matches the bitcode's target/ABI exactly.
    compiler_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_compile,
    )
    compile_env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_compile,
        variables = cc_common.create_compile_variables(
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
        ),
    )

    # Junk detection re-parses each source's AST inside the instrument action,
    # using the compile flags recorded in the bitcode (-grecord-command-line). So
    # the action needs the sources (else findAST gets a null AST and Mull
    # crashes), the dependency headers, and the toolchain (clang builtins /
    # resource dir), all staged at their original execroot paths.
    junk_detection_inputs = depset(
        ctx.files.srcs + [ctx.file.mull_config],
        transitive = [cc_toolchain.all_files] +
                     [dep[CcInfo].compilation_context.headers for dep in ctx.attr.deps],
    )

    instrumented_objects = []
    for bitcode in bitcode_objects:
        # 2. Embed mutants. mull-instrument honours mutators/excludePaths from
        #    the config pointed to by MULL_CONFIG.
        mutated = ctx.actions.declare_file(bitcode.basename + ".mutated.bc")
        instrument_args = ctx.actions.args()
        instrument_args.add(bitcode)
        instrument_args.add("-o", mutated)
        ctx.actions.run(
            executable = ctx.executable.mull_instrument,
            arguments = [instrument_args],
            inputs = depset([bitcode], transitive = [junk_detection_inputs]),
            outputs = [mutated],
            env = {"MULL_CONFIG": ctx.file.mull_config.path},
            mnemonic = "MullInstrument",
            progress_message = "Embedding mutants into %s" % bitcode.short_path,
        )

        # 3. Lower the instrumented bitcode to a native object.
        obj = ctx.actions.declare_file(bitcode.basename + ".mutated.o")
        recompile_args = ctx.actions.args()
        recompile_args.add("-c")
        recompile_args.add("-O0")
        if use_pic:
            recompile_args.add("-fPIC")
        recompile_args.add(mutated)
        recompile_args.add("-o", obj)
        ctx.actions.run(
            executable = compiler_path,
            arguments = [recompile_args],
            inputs = depset([mutated], transitive = [cc_toolchain.all_files]),
            outputs = [obj],
            env = compile_env,
            mnemonic = "MullCompileBitcode",
            progress_message = "Compiling instrumented %s" % obj.short_path,
        )
        instrumented_objects.append(obj)

    # 4. Link the instrumented objects with the test deps (the test framework and
    #    the library under test) into the final executable.
    if use_pic:
        new_compilation_outputs = cc_common.create_compilation_outputs(
            pic_objects = depset(instrumented_objects),
        )
    else:
        new_compilation_outputs = cc_common.create_compilation_outputs(
            objects = depset(instrumented_objects),
        )

    linking_outputs = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        name = ctx.label.name,
        compilation_outputs = new_compilation_outputs,
        linking_contexts = linking_contexts,
        output_type = "executable",
    )

    runfiles = ctx.runfiles()
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    # Not an executable rule: cc_common.link already declares an output named
    # after the target, which would collide with the auto-declared
    # ctx.outputs.executable. mull_runner_test consumes the binary via files.
    return [DefaultInfo(files = depset([linking_outputs.executable]), runfiles = runfiles)]

mull_instrumented_binary = rule(
    implementation = _mull_instrumented_binary_impl,
    doc = "Compile cc sources to bitcode, embed Mull mutants with mull-instrument, " +
          "and link a runnable test binary. Feed the result to mull_runner_test.",
    attrs = {
        "srcs": attr.label_list(allow_files = [".cpp", ".cc", ".cxx", ".c"]),
        "deps": attr.label_list(providers = [CcInfo]),
        "copts": attr.string_list(),
        "sanitize_bounds_copts": attr.string_list(
            default = ["-fsanitize=array-bounds", "-fsanitize-trap=array-bounds"],
            doc = "Extra compile flags baked into the bitcode. Defaults to a " +
                  "trapping array-bounds check: a mutated loop bound (e.g. " +
                  "`i < N` -> `i <= N`) is otherwise an *equivalent* mutant -- the " +
                  "extra iteration reads/writes one past the end without changing " +
                  "the result, so no assertion can kill it. The check makes the " +
                  "stray access trap (SIGILL) so mull-runner counts the mutant " +
                  "killed; the unmutated baseline keeps indices in range and never " +
                  "trips it. Set to [] to disable.",
        ),
        "mull_instrument": attr.label(
            default = Label("//:mull-instrument-21"),
            executable = True,
            # target cfg: build host == target here, and the target toolchain is
            # the one the mutation step pins to libstdc++ (so mull-instrument
            # links Mull's libstdc++-built libclang-cpp.so without an ABI clash).
            cfg = "target",
            doc = "Mull's standalone mull-instrument-<llvm_version> tool.",
        ),
        "mull_config": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "mull.yml, honoured at instrument time (mutators, excludePaths).",
        ),
        "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
    },
    toolchains = use_cc_toolchain(),
    fragments = ["cpp"],
)

def _mull_runner_test_impl(ctx):
    binary = ctx.attr.instrumented_binary[DefaultInfo].files.to_list()[0]
    runner = ctx.executable.mull_runner
    config = ctx.file.mull_config

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        is_executable = True,
        content = """#!/usr/bin/env bash
set -euo pipefail
export MULL_CONFIG="{config}"
exec "{runner}" -ide-reporter-show-killed "{binary}"
""".format(
            config = config.short_path,
            runner = runner.short_path,
            binary = binary.short_path,
        ),
    )

    runfiles = ctx.runfiles(files = [binary, runner, config])
    runfiles = runfiles.merge(ctx.attr.instrumented_binary[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.mull_runner[DefaultInfo].default_runfiles)

    return [DefaultInfo(executable = script, runfiles = runfiles)]

mull_runner_test = rule(
    implementation = _mull_runner_test_impl,
    test = True,
    doc = "Run mull-runner over a mull_instrumented_binary, re-executing it once " +
          "per mutant and failing on the score policy in the mull.yml config.",
    attrs = {
        "instrumented_binary": attr.label(
            mandatory = True,
            cfg = "target",
            doc = "Binary produced by mull_instrumented_binary.",
        ),
        "mull_runner": attr.label(
            default = Label("//rust/mull-tools:mull-runner-21"),
            executable = True,
            cfg = "target",
            doc = "The mull-runner-<llvm_version> binary from @mull.",
        ),
        "mull_config": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "mull.yml configuration file.",
        ),
    },
)

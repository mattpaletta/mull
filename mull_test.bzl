# buildifier: disable=module-docstring
#
# Public entry point for running a C/C++ test under Mull mutation testing
# from an integrating Bazel project.
#
# Typical usage (in an integrator's BUILD file):
#
#     load("@rules_cc//cc:defs.bzl", "cc_test")
#     load("@mull//:mull_test.bzl", "mull_test")
#
#     mull_test(
#         name = "my_unit_tests.mull",
#         srcs = ["my_unit_tests.cpp"],
#         deps = [":my_library"],
#         llvm_version = "21",
#     )
#
# The macro will:
#   1. Recompile the test sources with `-fpass-plugin=<mull pass plugin>`
#      so Mull's IR transformations are applied.
#   2. Emit a shell script that runs `mull-runner` against the resulting
#      binary and `mull-reporter` to produce an IDE report.
#   3. Tag the resulting test as `manual` so it does not run during normal
#      `bazel test //...` invocations.
load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library")

def _mull_runner_test_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    test_binary = ctx.executable.test_binary
    mull_runner = ctx.executable.mull_runner
    mull_reporter = ctx.executable.mull_reporter
    report_name = ctx.attr.report_name or ctx.label.name
    extra_runner_args = " ".join([shell.quote(a) for a in ctx.attr.runner_args])

    config_lines = ""
    if ctx.file.mull_config:
        config_lines = "export MULL_CONFIG=%s" % shell.quote(ctx.file.mull_config.short_path)

    content = """#!/bin/bash
set -euo pipefail

MULL_RUNNER={mull_runner}
MULL_REPORTER={mull_reporter}
TEST_BINARY={test_binary}
REPORT_NAME={report_name}
{config_export}

echo "[mull_test] Running mull-runner against ${{TEST_BINARY}}"
"${{MULL_RUNNER}}" --reporters SQLite --report-name "${{REPORT_NAME}}" {runner_args} "${{TEST_BINARY}}"

echo "[mull_test] Running mull-reporter"
"${{MULL_REPORTER}}" -report-name "${{REPORT_NAME}}_ide" "${{REPORT_NAME}}.sqlite"

echo "[mull_test] Done. Report: ${{REPORT_NAME}}.sqlite"
""".format(
        mull_runner = shell.quote(mull_runner.short_path),
        mull_reporter = shell.quote(mull_reporter.short_path),
        test_binary = shell.quote(test_binary.short_path),
        report_name = shell.quote(report_name),
        config_export = config_lines,
        runner_args = extra_runner_args,
    )

    ctx.actions.write(out, content, is_executable = True)

    runfiles = ctx.runfiles(files = [
        test_binary,
        mull_runner,
        mull_reporter,
    ])
    if ctx.file.mull_config:
        runfiles = runfiles.merge(ctx.runfiles(files = [ctx.file.mull_config]))
    runfiles = runfiles.merge(ctx.attr.test_binary[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.mull_runner[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.mull_reporter[DefaultInfo].default_runfiles)

    return [DefaultInfo(executable = out, runfiles = runfiles)]

_mull_runner_test = rule(
    implementation = _mull_runner_test_impl,
    test = True,
    attrs = {
        "test_binary": attr.label(mandatory = True, executable = True, cfg = "target"),
        "mull_runner": attr.label(mandatory = True, executable = True, cfg = "exec"),
        "mull_reporter": attr.label(mandatory = True, executable = True, cfg = "exec"),
        "mull_config": attr.label(allow_single_file = True),
        "runner_args": attr.string_list(default = []),
        "report_name": attr.string(default = ""),
    },
)

def mull_test(
        name,
        llvm_version,
        srcs = None,
        deps = None,
        copts = None,
        mull_config = None,
        runner_args = None,
        report_name = None,
        size = "large",
        timeout = "long",
        tags = None,
        **kwargs):
    """Run a C/C++ test under Mull mutation testing.

    Pass `srcs` (and optionally `deps`, `copts`, ...) just like a regular
    `cc_test`. The macro will:

      * Compile a testonly `cc_binary` with `-fpass-plugin=<mull>` so the
        mutation transformations are applied automatically (no need to
        set the copt yourself).
      * Generate and run a shell script that invokes `mull-runner` and
        `mull-reporter` against that binary.
      * Tag the resulting target with `manual` so it doesn't run during
        normal `bazel test //...` and only runs when invoked explicitly
        (e.g. `bazel test //path:my_test_mull`).

    Args:
        name: Unique name for the mull test target.
        llvm_version: Major version of LLVM ("19", "21", ...). Must match
            what `mull_llvm.configure(version = ...)` was set to in the
            consumer's MODULE.bazel.
        srcs: Sources for the instrumented test binary (required).
        deps: Deps for the instrumented test binary. Will be rebuilt as
            needed because the cc_binary sits in a different configuration
            than your regular cc_test (different copts).
        copts: Additional copts for the instrumented build.
        mull_config: Optional label pointing to a mull.yml config file
            that will be exported as `MULL_CONFIG` when the test runs.
        runner_args: Extra command-line arguments passed to `mull-runner`.
        report_name: Base name for the SQLite/IDE report files. Defaults
            to the macro `name`.
        size: Test size attribute (default "large").
        timeout: Test timeout attribute (default "long").
        tags: Extra tags. `manual` is always appended.
        **kwargs: Extra attributes forwarded to the generated cc_binary.
    """
    if srcs == None:
        fail("mull_test: `srcs` is required.")

    plugin = "@mull//:mull-cxx-ir-frontend-%s" % llvm_version
    mull_runner = "@mull//rust/mull-tools:mull-runner-%s" % llvm_version
    mull_reporter = "@mull//rust/mull-tools:mull-reporter-%s" % llvm_version

    instrumented_name = name + ".bin"

    final_tags = list(tags or [])
    if "manual" not in final_tags:
        final_tags.append("manual")
    if "mull" not in final_tags:
        final_tags.append("mull")

    # cc_binary doesn't accept `additional_compiler_inputs`, but cc_library
    # does. So we compile the sources into an intermediate cc_library with the
    # pass-plugin attached (which is where mull's IR transformations need to
    # run), then link them into the final executable via a thin cc_binary.
    instrumented_lib = instrumented_name + "_lib"

    cc_library(
        name = instrumented_lib,
        srcs = srcs,
        deps = (deps or []),
        copts = (copts or []) + [
            "-g",
            "-grecord-command-line",
            "-fpass-plugin=$(execpath %s)" % plugin,
        ],
        additional_compiler_inputs = [plugin],
        alwayslink = True,
        linkstatic = True,
        testonly = True,
        tags = final_tags,
        **kwargs
    )

    cc_binary(
        name = instrumented_name,
        deps = [":" + instrumented_lib],
        testonly = True,
        tags = final_tags,
    )

    _mull_runner_test(
        name = name,
        test_binary = ":" + instrumented_name,
        mull_runner = mull_runner,
        mull_reporter = mull_reporter,
        mull_config = mull_config,
        runner_args = runner_args or [],
        report_name = report_name or name,
        size = size,
        timeout = timeout,
        tags = final_tags,
    )

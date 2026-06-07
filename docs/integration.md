# Integrating Mull into a Bazel project

Mull exposes two public Starlark entry points for integrating projects:

1. `@mull//:mull_llvm.bzl` &mdash; a module extension (`mull_llvm`) that
   wires a single user-chosen LLVM version into your build. If that
   version is installed on the host machine, Mull uses the system
   install; otherwise it falls back to a source build of `llvm-project`.
2. `@mull//:mull_test.bzl` &mdash; a `mull_test` macro that recompiles a
   test binary with Mull's `-fpass-plugin` and emits a shell test that
   runs `mull-runner` / `mull-reporter` against the binary. The
   generated target is tagged `manual`.

These additions are opt-in. Mull's own internal build &mdash; which
iterates over every locally-available LLVM version &mdash; continues to
work unchanged.

## 1. Choosing an LLVM version

Add Mull to your `MODULE.bazel`:

```starlark
bazel_dep(name = "mull", version = "0.34.0")  # or whichever release

mull_llvm = use_extension("@mull//:mull_llvm.bzl", "mull_llvm")
mull_llvm.configure(version = "21")
use_repo(mull_llvm, "mull_llvm")
```

After this you can depend on `@mull_llvm//:libllvm`,
`@mull_llvm//:libclang`, `@mull_llvm//:clang`, `@mull_llvm//:clangxx`,
and `@mull_llvm//:llvm-profdata` from anywhere in your project.

> **Toolchain note.** Mull's own MODULE.bazel registers an LLVM
> toolchain inside a `dev_dependency` block, so when mull is consumed
> as a non-root module that registration is skipped. The integrator
> is responsible for registering a C++ toolchain. The simplest option
> is `register_toolchains("@rules_cc//cc:all")` to use the
> auto-detected system compiler.

### Source fallback (LLVM not installed on the host)

If you want builds to also work on machines where LLVM 21 is *not*
preinstalled, declare the upstream `llvm-project` archives in your
`MODULE.bazel` and run `llvm_configure` via the helper extension Mull
ships:

```starlark
http_archive = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

LLVM_TAG = "llvmorg-21.1.8"
http_archive(
    name = "llvm-raw",
    build_file_content = "# empty",
    sha256 = "",  # fill in for reproducible builds
    strip_prefix = "llvm-project-" + LLVM_TAG,
    urls = ["https://github.com/llvm/llvm-project/archive/refs/tags/{tag}.tar.gz".format(tag = LLVM_TAG)],
)

http_archive(
    name = "llvm_zlib",
    build_file = "@llvm-raw//utils/bazel/third_party_build:zlib-ng.BUILD",
    sha256 = "e36bb346c00472a1f9ff2a0a4643e590a254be6379da7cddd9daeb9a7f296731",
    strip_prefix = "zlib-ng-2.0.7",
    urls = ["https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.0.7.zip"],
)

http_archive(
    name = "llvm_zstd",
    build_file = "@llvm-raw//utils/bazel/third_party_build:zstd.BUILD",
    sha256 = "7c42d56fac126929a6a85dbc73ff1db2411d04f104fae9bdea51305663a83fd0",
    strip_prefix = "zstd-1.5.2",
    urls = ["https://github.com/facebook/zstd/releases/download/v1.5.2/zstd-1.5.2.tar.gz"],
)

mull_llvm_source = use_extension("@mull//:mull_llvm_source.bzl", "mull_llvm_source")
mull_llvm_source.configure(targets = ["AArch64", "X86"])
use_repo(mull_llvm_source, "llvm-project")
```

This is the same pattern used by the `mono` and `runtime` repositories.

`mull_llvm` will prefer the local install if present and silently fall
back to aliasing `@llvm-project` (the source build) if not.

## 2. Writing a `mull_test`

In any `BUILD` file:

```starlark
load("@mull//:mull_test.bzl", "mull_test")

mull_test(
    name = "calculator_test_mull",
    srcs = ["calculator_test.cpp"],
    deps = [":calculator"],
    llvm_version = "21",
    mull_config = ":mull.yml",       # optional
    runner_args = ["--allow-surviving"],  # optional
)
```

Run it explicitly:

```
bazel test //path/to:calculator_test_mull
```

It will not run as part of `bazel test //...` because of the `manual`
tag. The generated SQLite/IDE report files are written next to the test
in the runfiles directory.

### Notes / limitations

* `llvm_version` must match a major version that Mull's tools have been
  built for. Mull builds its tools for each LLVM version detected on
  the host where Mull itself is fetched. If you select version `21` but
  Mull's host environment only has `19` installed, the
  `mull-cxx-ir-frontend-21` plugin will not exist. Make sure the
  version is available on the machine fetching `@mull` (typically your
  CI builder).
* The `additional_compiler_inputs` attribute is used to make the pass
  plugin available at compile time. The `-fpass-plugin=$(execpath ...)`
  copt is resolved by Bazel into the real on-disk path of the plugin
  during the compile action, so no manual path handling is required by
  the caller.
* For granular control over how `mull-runner` is invoked, pass
  `runner_args = [...]`.

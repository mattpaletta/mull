# `mull` integration example

This is a self-contained Bazel module that consumes mull through the
public `bzl` APIs introduced in `mull_llvm.bzl` and `mull_test.bzl`. It
serves two purposes:

1. A copy-paste-able reference for projects that want to integrate
   mull. See `MODULE.bazel` and `BUILD.bazel`.
2. A CI smoke test (see `.github/workflows/integration-api.yml`).

## Layout

* `MODULE.bazel` &mdash; consumes mull via `local_path_override`, calls
  `mull_llvm.configure(version = "19")`.
* `calculator.{h,cpp}` &mdash; tiny "C++ not-quite-stdlib" used to
  exercise mutation testing.
* `calculator_test.cpp` &mdash; assertion-based test that should kill
  the mutants mull generates.
* `BUILD.bazel` &mdash; one `cc_test` (regular sanity) plus one
  `mull_test` (mutation testing, tagged `manual`).
* `mull.yml` &mdash; mutator configuration.

## Running locally

```sh
cd examples/integration_api

# Regular test
bazelisk test //:calculator_test

# Mutation test (explicit name needed because the macro tags it `manual`)
bazelisk test //:calculator_mull
```

Requires LLVM 19 to be installed on the host. The CI workflow
provisions it via `apt.llvm.org`.

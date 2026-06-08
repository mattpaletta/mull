Mutation Testing with Bazel
===========================

Mull usually plugs into a build as a clang pass-plugin (``-fpass-plugin``). When
the toolchain's clang is *statically* linked against LLVM -- as the hermetic
``toolchains_llvm`` release is -- the plugin's ``libclang-cpp.so`` and clang's
own static LLVM collide: two LLVM runtimes in one process, and clang
double-frees a managed static at exit. For that case Mull ships the standalone
``mull-instrument`` tool, and ``@mull//:mull.bzl`` wraps it in two rules:

* ``mull_instrumented_binary`` -- compiles your test sources to LLVM bitcode,
  embeds mutants with ``mull-instrument`` (a separate process, so no plugin is
  loaded into clang), then links an ordinary test binary.
* ``mull_runner_test`` -- a test rule that runs ``mull-runner`` over that binary,
  re-executing it once per mutant.

Because ``mull-instrument`` runs out-of-process and the mutation runtime is
embedded in the bitcode, the final link is a normal toolchain link: your
sources, the test framework and the code under test are all built by the single
Bazel C++ toolchain, so there is no ``std::`` ABI mismatch and no duplicated
LLVM.

MODULE.bazel
------------

Depend on Mull -- as a ``dev_dependency`` so consumers of your library don't
inherit Mull's build graph -- and register the hermetic LLVM its prebuilt tools
need:

.. code-block:: python

    bazel_dep(name = "mull", version = "0.34.0", dev_dependency = True)

    # Mull's prebuilt mull-instrument / libmull link the LLVM release's
    # libclang-cpp.so, so point Mull at a hermetic, downloaded LLVM of the
    # matching major version.
    mull_llvm = use_extension(
        "@mull//:mull_available_llvm_versions.bzl",
        "available_llvm_versions",
        dev_dependency = True,
    )
    mull_llvm.hermetic(
        version = "21",
        url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.8/LLVM-21.1.8-Linux-X64.tar.xz",
        strip_prefix = "LLVM-21.1.8-Linux-X64",
        sha256 = "b3b7f2801d15d50736acea3c73982994d025b01c2f035b91ae3b49d1b575732b",
        llvm_dylib = "libclang-cpp.so.21.1",
        clang_dylib = "libclang-cpp.so.21.1",
        exact_version = "21.1.8",
    )

``mull-instrument`` and ``libmull`` are built against the GNU C++ standard
library (libstdc++), so the mutation binary must link libstdc++ too. With
``toolchains_llvm`` you can register a second, libstdc++ flavour of the clang
toolchain and select it only for the mutation step:

.. code-block:: python

    llvm = use_extension("@toolchains_llvm//toolchain/extensions:llvm.bzl", "llvm", dev_dependency = True)
    llvm.toolchain(
        name = "llvm_toolchain_libstdcxx",
        llvm_version = "21.1.8",
        stdlib = {"linux-x86_64": "stdc++"},
    )
    use_repo(llvm, "llvm_toolchain_libstdcxx", "llvm_toolchain_libstdcxx_llvm")

Mull's runner is a Rust program, so also register the Rust toolchain it needs
(edition 2024); mirror the ``rust.toolchain(...)`` block from Mull's own
``MODULE.bazel``.

BUILD.bazel
-----------

.. code-block:: python

    load("@mull//:mull.bzl", "mull_instrumented_binary", "mull_runner_test")

    mull_instrumented_binary(
        name = "mutation_test_bin",
        testonly = True,
        srcs = glob(["src/**/*.test.cpp"]),
        copts = ["-std=c++20"],
        mull_config = "mull.yml",
        tags = ["manual"],  # keep it out of `bazel test //...`
        deps = [
            ":your_lib",
            "@googletest//:gtest",
            "@googletest//:gtest_main",
        ],
    )

    mull_runner_test(
        name = "mutation_test",
        # mull-runner re-runs the binary once per mutant, so wall time is
        # (mutant count x test runtime); raise the timeout accordingly.
        timeout = "eternal",
        instrumented_binary = ":mutation_test_bin",
        mull_config = "mull.yml",
        tags = ["manual"],
    )

``mull_instrument`` and ``mull_runner`` default to Mull's LLVM 21 tools
(``@mull//:mull-instrument-21`` and ``@mull//rust/mull-tools:mull-runner-21``).
Override both attributes to target a different hermetic LLVM.

mull.yml
--------

``mull-instrument`` reads its configuration from the file named by the
``MULL_CONFIG`` environment variable, which both rules set from ``mull_config``:

.. code-block:: yaml

    mutators:
      - cxx_default

    # Junk detection (AST re-parse) drops mutants Mull can't tie to a real source
    # construct. The rule already feeds the sources, dependency headers and the
    # toolchain into the instrument action, so the re-parse resolves.
    excludePaths:
      - .*\.test\.cpp$
      - .*/googletest/.*

See :doc:`MullConfig` for the full schema.

Running
-------

.. code-block:: bash

    bazel test //:mutation_test \
        --extra_toolchains=@llvm_toolchain_libstdcxx//:all

``--extra_toolchains`` selects the libstdc++ toolchain for the mutation build
only; the rest of your build keeps its default toolchain. Splitting this into
its own CI job (independent of the main build) lets you re-run it on its own.

Notes
-----

* **Junk detection inputs.** Mull re-parses each source's AST using the compile
  flags recorded in the bitcode (``-grecord-command-line``). The rule stages the
  sources, the dependency headers and the toolchain into the instrument action
  so that re-parse resolves; without the sources Mull dereferences a null AST
  and crashes.

* **Equivalent boundary mutants.** Mutating a loop bound (``i < N`` ->
  ``i <= N``) is often an *equivalent* mutant: the extra iteration reads/writes
  one past the end without changing the result, so no assertion can kill it. By
  default the rule compiles with ``-fsanitize=array-bounds -fsanitize-trap`` so
  the stray access traps (SIGILL) and mull-runner counts the mutant killed; the
  unmutated baseline keeps indices in range and never trips it. Set the
  ``sanitize_bounds_copts`` attribute to ``[]`` to disable this.

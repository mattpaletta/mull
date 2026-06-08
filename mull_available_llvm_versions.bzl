# buildifier: disable=module-docstring
load("@mull_package_info//:mull_package_info.bzl", "OS_NAME", "OS_VERSION")
load("@supported_llvm_versions//:supported_llvm_versions.bzl", "OS_VERSION_MAPPING")
load("//:bazel/os_detection.bzl", "is_macos", "is_redhat")

def _llvm_path(repository_ctx, version):
    if is_macos(repository_ctx):
        return "/opt/homebrew/opt/llvm@" + version
    return "/usr/lib/llvm-" + version

def _is_supported(repository_ctx, version):
    if is_redhat(repository_ctx):
        return repository_ctx.path("/usr/bin/llvm-config-%s" % version).exists
    path = _llvm_path(repository_ctx, version)
    return repository_ctx.path(path).exists

def _llvm_config(repository_ctx, version):
    if is_redhat(repository_ctx):
        return "/usr/bin/llvm-config-%s" % version
    path = _llvm_path(repository_ctx, version)
    return path + "/bin/llvm-config"

def _exact_version(repository_ctx, version):
    result = repository_ctx.execute([_llvm_config(repository_ctx, version), "--version"])
    return result.stdout.strip()

def _clang_paths(repository_ctx, version):
    if is_redhat(repository_ctx):
        return ["/usr/bin/clang", "/usr/bin/clang++"]
    path = _llvm_path(repository_ctx, version)
    return [path + "/bin/clang", path + "/bin/clang++"]

CONTENT = """
AVAILABLE_LLVM_VERSIONS = {VERSIONS}
EXACT_VERSION_MAPPING = {MAPPING}
CC_PATHS = {CC_MAPPING}
CXX_PATHS = {CXX_MAPPING}
HERMETIC_LLVM = {HERMETIC}
"""

def _llvm_versions_repo_impl(repository_ctx):
    available_versions = []
    mapping = {}
    cc_paths = {}
    cxx_paths = {}
    os_key = "%s:%s" % (OS_NAME, OS_VERSION)
    if OS_NAME.lower() == "macos":
        os_key = "macos"
    for version in OS_VERSION_MAPPING[os_key]:
        if _is_supported(repository_ctx, version):
            available_versions.append(version)
            mapping[version] = _exact_version(repository_ctx, version)
            compiler_paths = _clang_paths(repository_ctx, version)
            cc_paths[version] = compiler_paths[0]
            cxx_paths[version] = compiler_paths[1]

    # Hermetic LLVM versions are downloaded by the mull_deps extension and are
    # therefore "available" without a system installation. The compiler lives
    # inside the generated @llvm_<version> repo; the CC/CXX path fallbacks below
    # are only consumed by Mull's own cmake-based e2e tests, not by downstream
    # mutation-testing integrations.
    hermetic = json.decode(repository_ctx.attr.hermetic_json)
    for version, cfg in hermetic.items():
        if version not in available_versions:
            available_versions.append(version)
        mapping[version] = cfg["exact_version"] if cfg["exact_version"] else version
        cc_paths.setdefault(version, "clang")
        cxx_paths.setdefault(version, "clang++")

    if len(available_versions) == 0:
        fail("Could not find any supported LLVM versions installed")
    repository_ctx.file(
        "mull_llvm_versions.bzl",
        content = CONTENT.format(
            VERSIONS = str(available_versions),
            MAPPING = mapping,
            CC_MAPPING = cc_paths,
            CXX_MAPPING = cxx_paths,
            HERMETIC = repository_ctx.attr.hermetic_json,
        ),
    )
    repository_ctx.file(
        "BUILD",
        content = "",
    )

available_llvm_versions_repo = repository_rule(
    local = True,
    implementation = _llvm_versions_repo_impl,
    attrs = {
        "hermetic_json": attr.string(default = "{}"),
    },
)

def _available_llvm_versions_impl(module_ctx):
    hermetic = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.hermetic:
            hermetic[tag.version] = {
                "url": tag.url,
                "strip_prefix": tag.strip_prefix,
                "sha256": tag.sha256,
                "llvm_dylib": tag.llvm_dylib,
                "clang_dylib": tag.clang_dylib,
                "exact_version": tag.exact_version,
            }
    available_llvm_versions_repo(
        name = "available_llvm_versions",
        hermetic_json = json.encode(hermetic),
    )

available_llvm_versions = module_extension(
    implementation = _available_llvm_versions_impl,
    tag_classes = {
        "detect_available": tag_class(attrs = {}),
        # Declare an LLVM version that mull_deps should download hermetically
        # (e.g. from the official LLVM release) instead of expecting it to be
        # installed under /usr/lib/llvm-<version>.
        "hermetic": tag_class(attrs = {
            "version": attr.string(mandatory = True),
            "url": attr.string(mandatory = True),
            "strip_prefix": attr.string(),
            "sha256": attr.string(),
            "llvm_dylib": attr.string(default = "libLLVM.so"),
            "clang_dylib": attr.string(default = "libclang-cpp.so"),
            "exact_version": attr.string(),
        }),
    },
)

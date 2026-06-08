// mull-instrument: Standalone tool to apply mull mutations to LLVM bitcode.
//
// This tool provides an alternative to compiler plugins for environments where
// LLVM pass plugins don't work (static LLVM builds without shared libraries).
//
// Workflow:
//   1. clang++ -c -emit-llvm -g -grecord-command-line file.cpp -o file.bc
//   2. mull-instrument file.bc -o file-mutated.bc
//   3. clang++ -c file-mutated.bc -o file.o
//   4. clang++ file.o ... -o binary
//   5. mull-runner binary
//
// Reads from stdin and writes to stdout by default (like opt):
//   clang++ -c -emit-llvm -g file.cpp -o - | mull-instrument | clang++ -x ir - -o binary

#include "rust/mull-cxx-bridge/bridge.rs.h"
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/IRReader/IRReader.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/SourceMgr.h>
#include <llvm/Support/ToolOutputFile.h>
#include <mull/Driver.h>

static llvm::cl::opt<std::string> InputFile(llvm::cl::Positional, llvm::cl::desc("<input.bc>"),
                                            llvm::cl::init("-"));

static llvm::cl::opt<std::string> OutputFile("o", llvm::cl::desc("Output file (default: stdout)"),
                                             llvm::cl::value_desc("file"), llvm::cl::init("-"));

int main(int argc, char **argv) {
  // Note: we deliberately avoid llvm::InitLLVM here. It only installs crash
  // signal handlers and an llvm_shutdown, neither of which this short-lived
  // tool needs, and its symbols are not exported by the monolithic
  // libclang-cpp.so used by hermetic LLVM releases that ship no libLLVM.so.
  llvm::cl::ParseCommandLineOptions(
      argc, argv, "Apply mull mutation instrumentation to LLVM bitcode\n");

  llvm::LLVMContext context;
  llvm::SMDiagnostic err;

  auto module = llvm::parseIRFile(InputFile, err, context);
  if (!module) {
    err.print(argv[0], llvm::errs());
    return 1;
  }

  auto core = init_core_ffi(DiagOutput::Stderr);
  mull::mutateBitcode(*module, core->diag(), core->config());

  std::error_code ec;
  llvm::ToolOutputFile out(OutputFile, ec, llvm::sys::fs::OF_None);
  if (ec) {
    llvm::errs() << argv[0] << ": error opening '" << OutputFile << "': " << ec.message() << "\n";
    return 1;
  }

  // Output always goes to a file (or an explicitly redirected stdout), so we do
  // not need llvm::CheckBitcodeOutputToConsole to guard against a TTY.
  llvm::WriteBitcodeToFile(*module, out.os());

  out.keep();
  return 0;
}

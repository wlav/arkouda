#include "JITCWrapper.h"

#include "llvm/ExecutionEngine/Orc/LLJIT.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/IR/Module.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/Host.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"

#include <iostream>
#include <sstream>
#include <string>


static std::unique_ptr<llvm::orc::LLLazyJIT> theJIT;

// the client will get these once per session, but they are fixed for the
// host the server runs on, so may as well save them rather than deal with
// memory management of C strings in Chapel
static std::string hostName;
static std::string targetTriple;
static std::string dataLayout;
static std::string CPUFeatures;


extern "C" int JITMsg_initializeLLVMJIT() {
    /*
    // LLVM is already initialized
    const char* argv[] = {"JITMsg", "nullptr"};
    int argc = 1;
    llvm::InitLLVM X(argc, (const char**&)argv);
    */

    llvm::InitializeNativeTarget();
    llvm::InitializeNativeTargetAsmPrinter();

    theJIT = std::move(llvm::orc::LLLazyJITBuilder().create().get());

    return !(bool)theJIT;
}

extern "C" const char* JITMsg_getHost() {
   if (hostName.empty())
      hostName = llvm::sys::getHostCPUName().str();
   return hostName.c_str();
}

extern "C" const char* JITMsg_getTargetTriple() {
    if (targetTriple.empty())
        targetTriple = theJIT->getTargetTriple().str();
    return targetTriple.c_str();
}

extern "C" const char* JITMsg_getDataLayout() {
    if (dataLayout.empty())
        dataLayout = theJIT->getDataLayout().getStringRepresentation();
    return dataLayout.c_str();
}

extern "C" const char* JITMsg_getCPUFeatures() {
    if (CPUFeatures.empty()) {
        llvm::StringMap<bool> mfeat;
        llvm::sys::getHostCPUFeatures(mfeat);

        std::ostringstream sfeat;
        for (const auto& i: mfeat) {
            if (sfeat.tellp()) sfeat << ',';
            if (i.getValue()) sfeat << '+';
            else sfeat << '-';
            sfeat << i.first().str();
        }

        CPUFeatures = sfeat.str();
    }

    return CPUFeatures.c_str();
}

extern "C" gen_disp_t JITMsg_Compile(const char* fname, const char* func_ir) {
    static int module_count = 0;

    std::ostringstream modname;
    modname <<"JITMsg-" << module_count++;

    auto ctx = std::make_unique<llvm::LLVMContext>();

    llvm::SMDiagnostic diag;
    auto module = parseIR(llvm::MemoryBufferRef(func_ir, modname.str().c_str()), diag, *ctx);
    if (!module) {
        std::string msg;
        {
           llvm::raw_string_ostream OS(msg);
           diag.print("", OS);
        }
        std::cerr << "Error:" << msg << std::endl;
        return (gen_disp_t)nullptr;
    }

    // default optimization pipeline corresponding to -O3
    llvm::LoopAnalysisManager LAM;
    llvm::FunctionAnalysisManager FAM;
    llvm::CGSCCAnalysisManager CGAM;
    llvm::ModuleAnalysisManager MAM;

    llvm::PassBuilder PB;

    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    auto MPM = PB.buildPerModuleDefaultPipeline(llvm::OptimizationLevel::O3);
    MPM.run(*module, MAM);

    llvm::orc::ThreadSafeModule tsm(std::move(module), std::move(ctx));
    if (theJIT->addIRModule(std::move(tsm))) {
        std::cerr << "Failed to compile IR" << std::endl;
        return (gen_disp_t)nullptr;
    }

    auto symbol = theJIT->lookup(fname).get();
    return (gen_disp_t)symbol.toPtr<void*>();
}

extern "C" int JITMsg_ClearMainDyLib() {
    auto& mainlib = theJIT->getMainJITDylib();

    bool clearError  = (bool)mainlib.clear();
    bool removeError = (bool)mainlib.getDefaultResourceTracker()->remove();

    return int(clearError || removeError);
}

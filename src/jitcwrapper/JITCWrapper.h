#ifdef __cplusplus
extern "C" {
#endif

// initialize the JIT; returns 0 on success
int JITMsg_initializeLLVMJIT(void);

// get host target information
const char* JITMsg_getHost(void);
const char* JITMsg_getTargetTriple(void);
const char* JITMsg_getDataLayout(void);
const char* JITMsg_getCPUFeatures(void);

typedef void* gen_disp_t;

// compile the given IR to symbol fname; returns a C function
// pointer to the method or NULL on failure
gen_disp_t JITMsg_Compile(const char* fname, const char* func_ir);

// clear the JIT state to allow symbol replacement
int JITMsg_ClearMainDyLib(void);

#ifdef __cplusplus
}
#endif
